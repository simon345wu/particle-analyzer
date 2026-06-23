import 'dart:math' as math;
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// 單個咖啡顆粒的幾何與統計數據記錄
class ParticleRecord {
  final int id;
  final double areaPx;
  final double equivDiameterPx;
  final double equivDiameterUm;
  final double circularity;
  final double cx;
  final double cy;

  ParticleRecord({
    required this.id,
    required this.areaPx,
    required this.equivDiameterPx,
    required this.equivDiameterUm,
    required this.circularity,
    required this.cx,
    required this.cy,
  });
}

/// 粒徑分析的最終統計與影像路徑結果
class AnalysisResult {
  final List<ParticleRecord> particles;
  final Map<String, double> statistics;
  final String annotatedImagePath;
  final String binaryMaskPath;
  final double scalePxPerMm;
  final String? warpedImagePath;
  final String? squareDetectionPath;

  AnalysisResult({
    required this.particles,
    required this.statistics,
    required this.annotatedImagePath,
    required this.binaryMaskPath,
    required this.scalePxPerMm,
    this.warpedImagePath,
    this.squareDetectionPath,
  });
}

/// OpenCV 核心分析引擎 (對齊 Python 版本演算法)
class OpenCVAnalyzer {
  
  /// 執行顆粒分析管線
  ///
  /// * [imagePath] 待分析的影像本機路徑
  /// * [outDir] 分析結果圖檔的存取目錄
  /// * [scalePxPerMm] 比例尺 (像素/公釐)
  /// * [minDiameterUm] 最小直徑過濾門檻 (微米)
  /// * [maxDiameterUm] 最大直徑過濾門檻 (微米)
  /// * [minCircularity] 最小圓形度過濾門檻
  /// * [distThresh] 分水嶺演算法距離轉換門檻 (像素)
  /// * [invert] 咖啡粉顏色是否亮於背景
  /// * [autoCalibrate] 是否自動偵測 $15\text{cm} \times 15\text{cm}$ 校正框進行透視校正
  /// * [squareMm] 校正框的實際物理邊長 (單位：mm，預設 150)
  /// * [targetResolution] 透視校正後的解析度 (像素/mm，預設 10)
  /// * [marginMm] 內縮裁切邊界 (mm，預設 2)
  static AnalysisResult runPipeline({
    required String imagePath,
    required String outDir,
    required double scalePxPerMm,
    required double minDiameterUm,
    required double maxDiameterUm,
    required double minCircularity,
    required double distThresh,
    bool invert = false,
    bool autoCalibrate = false,
    double squareMm = 150.0,
    double targetResolution = 10.0,
    double marginMm = 5.0,
  }) {
    // 1. 讀取影像
    final img = cv.imread(imagePath);
    if (img.isEmpty) {
      throw Exception("無法讀取圖片: $imagePath");
    }

    double finalScale = scalePxPerMm;
    cv.Mat activeImage = img;
    String? warpedPath;
    String? detectionPath;

    if (autoCalibrate) {
      final corners = _findSquareCorners(img);
      if (corners == null) {
        img.dispose();
        throw Exception("無法偵測到 ${squareMm.toStringAsFixed(0)}mm 校正框，請確認四角完整入鏡，或切換至手動模式");
      }

      // 繪製校正框標記圖
      final overlay = _drawSquareOverlay(img, corners);
      detectionPath = "$outDir/square_detection.jpg";
      cv.imwrite(detectionPath, overlay);
      overlay.dispose();

      // 透視校正並攤平影像
      final sizePx = (squareMm * targetResolution).round();
      final srcCorners = corners;
      final dstCorners = cv.VecPoint.fromList([
        cv.Point(0, 0),
        cv.Point(sizePx - 1, 0),
        cv.Point(sizePx - 1, sizePx - 1),
        cv.Point(0, sizePx - 1),
      ]);

      final M = cv.getPerspectiveTransform(srcCorners, dstCorners);
      final warped = cv.warpPerspective(img, M, (sizePx, sizePx));
      warpedPath = "$outDir/warped.jpg";
      cv.imwrite(warpedPath, warped);

      // 內縮邊界裁剪，避免框線本身被誤判為顆粒
      final marginPx = (marginMm * targetResolution).round();
      final h = warped.rows;
      final w = warped.cols;
      final cropMargin = math.max(0, math.min(marginPx, math.min(h ~/ 4, w ~/ 4)));
      final cropped = cv.Mat.fromMat(warped, roi: cv.Rect(cropMargin, cropMargin, w - 2 * cropMargin, h - 2 * cropMargin));
      activeImage = cropped.clone();
      finalScale = targetResolution;

      // 釋放中間臨時 Mat
      corners.dispose();
      dstCorners.dispose();
      M.dispose();
      cropped.dispose();
      warped.dispose();
    }

    // 2. 前處理：灰階化與高斯模糊
    final gray = cv.cvtColor(activeImage, cv.COLOR_BGR2GRAY);
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);

    // 3. 自動大津二值化 (Otsu Threshold)
    final threshType = invert ? cv.THRESH_BINARY : cv.THRESH_BINARY_INV;
    final (_, binary) = cv.threshold(
      blurred, 
      0, 
      255, 
      threshType | cv.THRESH_OTSU
    );

    // 4. 形態學處理 (消除細微噪聲並填補微小空洞)
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    final opened = cv.morphologyEx(binary, cv.MORPH_OPEN, kernel);
    final closed = cv.morphologyEx(opened, cv.MORPH_CLOSE, kernel);

    // 5. 分水嶺分割 (Watershed Segmentation)
    final (dist, _) = cv.distanceTransform(closed, cv.DIST_L2, 5, cv.DIST_LABEL_CCOMP);
    
    // 尋找局部極大值作為前景種子點
    final (_, sureFg) = cv.threshold(dist, distThresh, 255, cv.THRESH_BINARY);
    final sureFgUint8 = sureFg.convertTo(cv.MatType.CV_8UC1);
    
    // 連通元件標籤
    final markers = cv.Mat.empty();
    cv.connectedComponents(sureFgUint8, markers, 8, cv.MatType.CV_32S, cv.CCL_DEFAULT);
    
    // 將標記轉為 32-bit signed 以符合分水嶺函數要求
    final markers32S = markers.convertTo(cv.MatType.CV_32SC1);
    final colorImg = cv.cvtColor(closed, cv.COLOR_GRAY2BGR);
    cv.watershed(colorImg, markers32S);

    // 6. 提取與過濾顆粒資訊
    final List<ParticleRecord> particles = [];
    final int h = activeImage.rows;
    final int intW = activeImage.cols;
    
    // 尋找各個獨立分水嶺標籤的輪廓與屬性
    final (contours, _) = cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    
    int particleId = 2; // 起始標籤編號 (0是未知, 1是背景)
    
    for (int i = 0; i < contours.length; i++) {
      final cnt = contours.elementAt(i);
      final areaPx = cv.contourArea(cnt);
      final perimeterPx = cv.arcLength(cnt, true);
      
      if (areaPx <= 0 || perimeterPx <= 0) continue;
      
      // 計算圓形度 (Circularity)
      final circularity = (4 * math.pi * areaPx) / (perimeterPx * perimeterPx);
      
      // 計算等效圓直徑 (ECD)
      final equivDiameterPx = math.sqrt((4 * areaPx) / math.pi);
      final equivDiameterUm = (equivDiameterPx / finalScale) * 1000.0;
      
      // 計算外接矩形以過濾邊界切半顆粒
      final rect = cv.boundingRect(cnt);
      final touchesBorder = rect.x <= 1 || 
                            rect.y <= 1 || 
                            (rect.x + rect.width) >= intW - 1 || 
                            (rect.y + rect.height) >= h - 1;
      
      // 過濾條件 (符合尺寸門檻、圓形度且不觸摸邊界)
      if (equivDiameterUm >= minDiameterUm && 
          equivDiameterUm <= maxDiameterUm && 
          circularity >= minCircularity && 
          !touchesBorder) {
        
        // 利用 Moment 計算重心
        final moments = cv.moments(cv.Mat.fromVec(cnt));
        final double cx = moments.m10 / moments.m00;
        final double cy = moments.m01 / moments.m00;
        
        particles.add(ParticleRecord(
          id: particleId++,
          areaPx: areaPx,
          equivDiameterPx: equivDiameterPx,
          equivDiameterUm: equivDiameterUm,
          circularity: circularity,
          cx: cx,
          cy: cy,
        ));
      }
    }

    // 7. 計算粒徑分佈統計數據
    final Map<String, double> statistics = {};
    if (particles.isNotEmpty) {
      final listD = particles.map((p) => p.equivDiameterUm).toList()..sort();
      final double totalCount = listD.length.toDouble();
      
      final mean = listD.reduce((a, b) => a + b) / totalCount;
      final median = listD[(totalCount / 2).floor()];
      
      // 計算標準差
      final variance = listD.map((d) => math.pow(d - mean, 2)).reduce((a, b) => a + b) / totalCount;
      final stdDev = math.sqrt(variance);
      
      // 數量百分位數 Dn10, Dn50, Dn90
      final dn10 = listD[(totalCount * 0.10).floor()];
      final dn50 = listD[(totalCount * 0.50).floor()];
      final dn90 = listD[(totalCount * 0.90).floor()];

      // 體積百分位數 Dv10, Dv50, Dv90 (V = pi/6 * d^3)
      final List<double> volumes = listD.map((d) => (math.pi / 6.0) * math.pow(d, 3)).toList();
      final double totalVol = volumes.reduce((a, b) => a + b);
      
      List<double> cumVolPct = [];
      double runningSum = 0;
      for (var vol in volumes) {
        runningSum += vol;
        cumVolPct.add((runningSum / totalVol) * 100.0);
      }
      
      // 簡單的線性插值計算 Dv
      double interpolate(double targetPct) {
        for (int i = 0; i < cumVolPct.length; i++) {
          if (cumVolPct[i] >= targetPct) {
            if (i == 0) return listD[0];
            final p0 = cumVolPct[i - 1];
            final p1 = cumVolPct[i];
            final d0 = listD[i - 1];
            final d1 = listD[i];
            return d0 + (targetPct - p0) * (d1 - d0) / (p1 - p0);
          }
        }
        return listD.last;
      }

      statistics['count'] = totalCount;
      statistics['mean_um'] = mean;
      statistics['median_um'] = median;
      statistics['std_um'] = stdDev;
      statistics['Dn10_um'] = dn10;
      statistics['Dn50_um'] = dn50;
      statistics['Dn90_um'] = dn90;
      statistics['Dv10_um'] = interpolate(10.0);
      statistics['Dv50_um'] = interpolate(50.0);
      statistics['Dv90_um'] = interpolate(90.0);
    } else {
      statistics['count'] = 0;
      statistics['mean_um'] = 0;
      statistics['median_um'] = 0;
      statistics['std_um'] = 0;
      statistics['Dn10_um'] = 0;
      statistics['Dn50_um'] = 0;
      statistics['Dn90_um'] = 0;
      statistics['Dv10_um'] = 0;
      statistics['Dv50_um'] = 0;
      statistics['Dv90_um'] = 0;
    }

    // 8. 儲存標註結果與遮罩圖檔以供 UI 呈現
    final String annotatedPath = "$outDir/annotated.jpg";
    final String maskPath = "$outDir/binary_mask.jpg";
    
    // 繪製輪廓標註 (在原圖上畫框)
    final annotatedImg = activeImage.clone();
    for (int i = 0; i < contours.length; i++) {
      cv.drawContours(annotatedImg, contours, i, cv.Scalar(0, 255, 0, 0), thickness: 1);
    }
    
    cv.imwrite(annotatedPath, annotatedImg);
    cv.imwrite(maskPath, closed);

    // 釋放 C++ 底層 Mat 記憶體，防止 Mobile 記憶體洩漏
    if (autoCalibrate) {
      activeImage.dispose();
    }
    img.dispose();
    gray.dispose();
    blurred.dispose();
    binary.dispose();
    opened.dispose();
    closed.dispose();
    dist.dispose();
    sureFg.dispose();
    sureFgUint8.dispose();
    markers.dispose();
    markers32S.dispose();
    colorImg.dispose();
    annotatedImg.dispose();

    return AnalysisResult(
      particles: particles,
      statistics: statistics,
      annotatedImagePath: annotatedPath,
      binaryMaskPath: maskPath,
      scalePxPerMm: finalScale,
      warpedImagePath: warpedPath,
      squareDetectionPath: detectionPath,
    );
  }

  static double _dist(cv.Point p1, cv.Point p2) {
    final dx = p1.x - p2.x;
    final dy = p1.y - p2.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  static List<cv.Point> _orderCorners(List<cv.Point> pts) {
    assert(pts.length == 4);
    cv.Point tl = pts[0];
    cv.Point br = pts[0];
    double minSum = (pts[0].x + pts[0].y).toDouble();
    double maxSum = (pts[0].x + pts[0].y).toDouble();

    cv.Point tr = pts[0];
    cv.Point bl = pts[0];
    double minDiff = (pts[0].y - pts[0].x).toDouble();
    double maxDiff = (pts[0].y - pts[0].x).toDouble();

    for (int i = 1; i < 4; i++) {
      final p = pts[i];
      final sum = (p.x + p.y).toDouble();
      final diff = (p.y - p.x).toDouble();

      if (sum < minSum) {
        minSum = sum;
        tl = p;
      }
      if (sum > maxSum) {
        maxSum = sum;
        br = p;
      }
      if (diff < minDiff) {
        minDiff = diff;
        tr = p;
      }
      if (diff > maxDiff) {
        maxDiff = diff;
        bl = p;
      }
    }
    return [tl, tr, br, bl];
  }

  static cv.VecPoint? _findSquareCorners(
    cv.Mat image, {
    double minAreaRatio = 0.10,
    double maxAreaRatio = 0.97,
    double sideRatioTolerance = 1.35,
  }) {
    final gray = cv.cvtColor(image, cv.COLOR_BGR2GRAY);
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    final edges = cv.canny(blurred, 30, 100);

    final dilateKernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
    final edgesDilated = cv.dilate(edges, dilateKernel, iterations: 2);
    final erodeKernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    final edgesProcessed = cv.erode(edgesDilated, erodeKernel, iterations: 1);

    final (contours, _) = cv.findContours(edgesProcessed, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
    final double imgArea = (image.rows * image.cols).toDouble();

    double maxArea = -1;
    List<cv.Point>? bestOrdered;

    for (int i = 0; i < contours.length; i++) {
      final cnt = contours.elementAt(i);
      final area = cv.contourArea(cnt);
      if (area < imgArea * minAreaRatio || area > imgArea * maxAreaRatio) {
        continue;
      }
      final peri = cv.arcLength(cnt, true);
      final approx = cv.approxPolyDP(cnt, 0.02 * peri, true);
      if (approx.length != 4 || !cv.isContourConvex(approx)) {
        approx.dispose();
        continue;
      }

      final ptsList = [
        approx.elementAt(0),
        approx.elementAt(1),
        approx.elementAt(2),
        approx.elementAt(3),
      ];
      final ordered = _orderCorners(ptsList);

      final double s0 = _dist(ordered[0], ordered[1]);
      final double s1 = _dist(ordered[1], ordered[2]);
      final double s2 = _dist(ordered[2], ordered[3]);
      final double s3 = _dist(ordered[3], ordered[0]);

      final minSide = [s0, s1, s2, s3].reduce(math.min);
      final maxSide = [s0, s1, s2, s3].reduce(math.max);

      if (minSide == 0 || maxSide / minSide > sideRatioTolerance) {
        approx.dispose();
        continue;
      }

      if (area > maxArea) {
        maxArea = area;
        bestOrdered = ordered;
      }
      approx.dispose();
    }

    gray.dispose();
    blurred.dispose();
    edges.dispose();
    dilateKernel.dispose();
    edgesDilated.dispose();
    erodeKernel.dispose();
    edgesProcessed.dispose();
    contours.dispose();

    if (bestOrdered != null) {
      return cv.VecPoint.fromList(bestOrdered);
    }
    return null;
  }

  static cv.Mat _drawSquareOverlay(cv.Mat image, cv.VecPoint corners) {
    final out = image.clone();
    final ptsVecVec = cv.VecVecPoint.fromList([[
      corners.elementAt(0),
      corners.elementAt(1),
      corners.elementAt(2),
      corners.elementAt(3),
    ]]);
    cv.drawContours(out, ptsVecVec, 0, cv.Scalar(0, 0, 255, 0), thickness: 4);
    ptsVecVec.dispose();

    for (int i = 0; i < 4; i++) {
      final p = corners.elementAt(i);
      cv.circle(out, p, 10, cv.Scalar(0, 255, 255, 0), thickness: -1);
      cv.putText(
        out,
        i.toString(),
        cv.Point(p.x + 15, p.y),
        cv.FONT_HERSHEY_SIMPLEX,
        1.0,
        cv.Scalar(0, 255, 255, 0),
        thickness: 2,
      );
    }
    return out;
  }
}
