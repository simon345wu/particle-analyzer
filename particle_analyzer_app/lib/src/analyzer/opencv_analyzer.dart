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

  AnalysisResult({
    required this.particles,
    required this.statistics,
    required this.annotatedImagePath,
    required this.binaryMaskPath,
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
  static AnalysisResult runPipeline({
    required String imagePath,
    required String outDir,
    required double scalePxPerMm,
    required double minDiameterUm,
    required double maxDiameterUm,
    required double minCircularity,
    required double distThresh,
    bool invert = false,
  }) {
    // 1. 讀取影像
    final img = cv.imread(imagePath);
    if (img.isEmpty) {
      throw Exception("無法讀取圖片: $imagePath");
    }

    // 2. 前處理：灰階化與高斯模糊
    final gray = cv.cvtColor(img, cv.COLOR_BGR2GRAY);
    final blurred = cv.GaussianBlur(gray, (5, 5), 0);

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
    final dist = cv.distanceTransform(closed, cv.DIST_L2, 5);
    
    // 尋找局部極大值作為前景種子點
    final (_, sureFg) = cv.threshold(dist, distThresh, 255, cv.THRESH_BINARY);
    final sureFgUint8 = sureFg.convertTo(cv.MatType.CV_8UC1);
    
    // 連通元件標籤
    final (markers, _) = cv.connectedComponents(sureFgUint8);
    
    // 將標記轉為 32-bit signed 以符合分水嶺函數要求
    final markers32S = markers.convertTo(cv.MatType.CV_32SC1);
    final colorImg = cv.cvtColor(closed, cv.COLOR_GRAY2BGR);
    cv.watershed(colorImg, markers32S);

    // 6. 提取與過濾顆粒資訊
    final List<ParticleRecord> particles = [];
    final int h = img.rows;
    final int intW = img.cols;
    
    // 尋找各個獨立分水嶺標籤的輪廓與屬性
    // 在這裡我們簡化邏輯：透過輪廓偵測或標籤遍歷獲取各顆粒的特徵
    // 我們直接使用 opencv_dart 尋找 closed 的輪廓作為基本顆粒代表
    final (contours, _) = cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    
    int particleId = 2; // 起始標籤編號 (0是未知, 1是背景)
    
    for (int i = 0; i < contours.length; i++) {
      final cnt = contours.at(i);
      final areaPx = cv.contourArea(cnt);
      final perimeterPx = cv.arcLength(cnt, true);
      
      if (areaPx <= 0 || perimeterPx <= 0) continue;
      
      // 計算圓形度 (Circularity)
      final circularity = (4 * math.pi * areaPx) / (perimeterPx * perimeterPx);
      
      // 計算等效圓直徑 (ECD)
      final equivDiameterPx = math.sqrt((4 * areaPx) / math.pi);
      final equivDiameterUm = (equivDiameterPx / scalePxPerMm) * 1000.0;
      
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
        final moments = cv.moments(cnt);
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
    final annotatedImg = img.clone();
    for (int i = 0; i < contours.length; i++) {
      cv.drawContours(annotatedImg, contours, i, cv.Scalar(0, 255, 0, 0), thickness: 1);
    }
    
    cv.imwrite(annotatedPath, annotatedImg);
    cv.imwrite(maskPath, closed);

    // 釋放 C++ 底層 Mat 記憶體，防止 Mobile 記憶體洩漏
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
    );
  }
}
