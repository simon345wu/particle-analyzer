import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'src/analyzer/opencv_analyzer.dart';
import 'src/models/profile_model.dart';
import 'src/services/profile_manager.dart';
import 'src/localization/translations.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

enum ImageViewType { calibration, particles, mask, countChart, volumeChart }

// 宣告參數的 StateProvider
final scaleProvider = StateProvider<double>((ref) => 25.0);
final minDiameterProvider = StateProvider<double>((ref) => 20.0);
final maxDiameterProvider = StateProvider<double>((ref) => 2000.0);
final circularityProvider = StateProvider<double>((ref) => 0.5);
final distThreshProvider = StateProvider<double>((ref) => 0.5);
final invertProvider = StateProvider<bool>((ref) => false);
final autoCalibrateProvider = StateProvider<bool>((ref) => true);
final squareSizeProvider = StateProvider<double>((ref) => 150.0);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Coffee Particle Analyzer',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF6F4E37), // 咖啡色主調
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6F4E37),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  String? _selectedImagePath;
  AnalysisResult? _analysisResult;
  bool _isLoading = false;
  String _statusMessage = "請點選拍照或選擇圖片開始分析";
  ImageViewType _currentViewType = ImageViewType.particles;
  int _selectedTab = 0;

  String _tr(String key) => tr(ref, key);

  String _translateStatusMessage(String status, AppLanguage lang) {
    if (status.contains("請點選") || status.contains("Please select") || status.contains("Please tap")) {
      return lang == AppLanguage.zh ? "請點選拍照或選擇圖片開始分析" : "Please tap camera or gallery to start analysis";
    }
    if (status.contains("OpenCV 分析運算中")) {
      return lang == AppLanguage.zh ? "OpenCV 分析運算中..." : "OpenCV analysis in progress...";
    }
    if (status.contains("分析完成")) {
      final count = RegExp(r'\d+').stringMatch(status) ?? '0';
      return lang == AppLanguage.zh ? "分析完成！偵測到 $count 顆有效顆粒。" : "Analysis complete! Detected $count valid particles.";
    }
    if (status.contains("分析失敗")) {
      final err = status.split(":").last;
      return lang == AppLanguage.zh ? "分析失敗: $err" : "Analysis failed: $err";
    }
    if (status.contains("載入測試影像中")) {
      return lang == AppLanguage.zh ? "載入測試影像中..." : "Loading test image...";
    }
    if (status.contains("載入測試影像失敗")) {
      final err = status.split(":").last;
      return lang == AppLanguage.zh ? "載入測試影像失敗: $err" : "Failed to load test image: $err";
    }
    if (status.contains("開啟相機中")) {
      return lang == AppLanguage.zh ? "開啟相機中..." : "Opening camera...";
    }
    if (status.contains("讀取相簿中")) {
      return lang == AppLanguage.zh ? "讀取相簿中..." : "Opening gallery...";
    }
    if (status.contains("已取消選擇")) {
      return lang == AppLanguage.zh ? "已取消選擇" : "Selection cancelled";
    }
    if (status.contains("讀取影像失敗")) {
      final err = status.split(":").last;
      return lang == AppLanguage.zh ? "讀取影像失敗: $err" : "Failed to read image: $err";
    }
    return status;
  }

  // 模擬觸發分析程序
  Future<void> _runAnalysis() async {
    if (_selectedImagePath == null) return;

    setState(() {
      _isLoading = true;
      _statusMessage = "OpenCV 分析運算中...";
    });

    try {
      // 讀取 Slider 當前狀態值
      final scale = ref.read(scaleProvider);
      final minD = ref.read(minDiameterProvider);
      final maxD = ref.read(maxDiameterProvider);
      final circ = ref.read(circularityProvider);
      final distT = ref.read(distThreshProvider);
      final invert = ref.read(invertProvider);
      final autoCalibrate = ref.read(autoCalibrateProvider);
      final squareSize = ref.read(squareSizeProvider);

      // 取得臨時目錄以儲存輸出結果
      final outDir = Directory.systemTemp.path;

      // 執行 OpenCV 分析管線
      // 實務上在手機上應使用 Isolate.run 執行以下同步 CPU 密集任務
      final result = OpenCVAnalyzer.runPipeline(
        imagePath: _selectedImagePath!,
        outDir: outDir,
        scalePxPerMm: scale,
        minDiameterUm: minD,
        maxDiameterUm: maxD,
        minCircularity: circ,
        distThresh: distT,
        invert: invert,
        autoCalibrate: autoCalibrate,
        squareMm: squareSize,
      );

      setState(() {
        _analysisResult = result;
        _isLoading = false;
        _statusMessage = "分析完成！偵測到 ${result.particles.length} 顆有效顆粒。";
        if (autoCalibrate && result.squareDetectionPath != null) {
          _currentViewType = ImageViewType.calibration;
        } else {
          _currentViewType = ImageViewType.particles;
        }
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = "分析失敗: $e";
      });
    }
  }

  // 載入測試影像並複製到暫存區以供 OpenCV 讀取
  Future<void> _loadTestImage() async {
    setState(() {
      _isLoading = true;
      _statusMessage = "載入測試影像中...";
    });
    try {
      final byteData = await rootBundle.load('assets/synthetic_particles.jpg');
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/synthetic_particles.jpg');
      await file.writeAsBytes(byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
      
      setState(() {
        _selectedImagePath = file.path;
      });
      await _runAnalysis();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = "載入測試影像失敗: $e";
      });
    }
  }

  // 從相簿選擇或使用相機拍照
  Future<void> _pickImage(ImageSource source) async {
    setState(() {
      _isLoading = true;
      _statusMessage = source == ImageSource.camera ? "開啟相機中..." : "讀取相簿中...";
    });
    try {
      final picker = ImagePicker();
      final XFile? pickedFile = await picker.pickImage(
        source: source,
        maxWidth: 2000,
        maxHeight: 2000,
      );
      
      if (pickedFile != null) {
        setState(() {
          _selectedImagePath = pickedFile.path;
        });
        await _runAnalysis();
      } else {
        setState(() {
          _isLoading = false;
          _statusMessage = "已取消選擇";
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = "讀取影像失敗: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 監聽狀態，當任何一個滑桿改變時自動重新分析 (Debounce 可以另外包裝)
    ref.listen(scaleProvider, (_, __) => _runAnalysis());
    ref.listen(minDiameterProvider, (_, __) => _runAnalysis());
    ref.listen(maxDiameterProvider, (_, __) => _runAnalysis());
    ref.listen(circularityProvider, (_, __) => _runAnalysis());
    ref.listen(distThreshProvider, (_, __) => _runAnalysis());
    ref.listen(invertProvider, (_, __) => _runAnalysis());
    ref.listen(autoCalibrateProvider, (_, __) => _runAnalysis());
    ref.listen(squareSizeProvider, (_, __) => _runAnalysis());

    final isMobile = MediaQuery.of(context).size.width < 700;
    final lang = ref.watch(languageProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_tr('app_title')),
        backgroundColor: const Color(0xFF3E2723),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(languageProvider.notifier).state =
                  lang == AppLanguage.zh ? AppLanguage.en : AppLanguage.zh;
            },
            child: Text(
              lang == AppLanguage.zh ? "EN" : "中",
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _selectedTab == 0
          ? (isMobile ? _buildMobileLayout() : _buildDesktopLayout())
          : _selectedTab == 1
              ? _buildHistoryLayout(isMobile)
              : _buildAboutLayout(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        selectedItemColor: const Color(0xFFD7CCC8), // 淺咖啡
        unselectedItemColor: Colors.grey,
        backgroundColor: const Color(0xFF3E2723),
        onTap: (index) {
          setState(() {
            _selectedTab = index;
          });
        },
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.analytics),
            label: _tr('tab_analyzer'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.history),
            label: _tr('tab_history'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.info_outline),
            label: _tr('tab_about'),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout() {
    final lang = ref.watch(languageProvider);
    final displayStatus = _translateStatusMessage(_statusMessage, lang);

    return SingleChildScrollView(
      child: Column(
        children: [
          // 影像與圖表切換區 (設定固定高度以防 Column 內 layout 問題)
          SizedBox(
            height: 380,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: _buildImageArea(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              displayStatus,
              style: const TextStyle(color: Colors.amberAccent),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          // 下方統計數據板
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: _buildStatsArea(isMobile: true),
          ),
          const SizedBox(height: 12),
          // 調參控制台 (移除 Container 背景，整合進滾動列中)
          _buildControlPanel(isMobile: true),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout() {
    final lang = ref.watch(languageProvider);
    final displayStatus = _translateStatusMessage(_statusMessage, lang);

    return Row(
      children: [
        // 左側：影像呈現與結果直方圖
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Expanded(flex: 5, child: _buildImageArea()),
                const SizedBox(height: 8),
                Text(displayStatus, style: const TextStyle(color: Colors.amberAccent)),
                const SizedBox(height: 8),
                Expanded(flex: 3, child: _buildStatsArea(isMobile: false)),
              ],
            ),
          ),
        ),
        // 右側：調參控制台 (GUI 控制板)
        Container(
          width: 320,
          color: const Color(0xFF1E1E1E),
          child: SingleChildScrollView(
            child: _buildControlPanel(isMobile: false),
          ),
        ),
      ],
    );
  }

  Widget _buildImageArea() {
    return Card(
      color: Colors.black26,
      child: Column(
        children: [
          if (_analysisResult != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (ref.watch(autoCalibrateProvider) && _analysisResult!.squareDetectionPath != null) ...[
                      ChoiceChip(
                        label: Text(_tr('view_calibration')),
                        selected: _currentViewType == ImageViewType.calibration,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _currentViewType = ImageViewType.calibration;
                            });
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                    ChoiceChip(
                      label: Text(_tr('view_particles')),
                      selected: _currentViewType == ImageViewType.particles,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _currentViewType = ImageViewType.particles;
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(_tr('view_mask')),
                      selected: _currentViewType == ImageViewType.mask,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _currentViewType = ImageViewType.mask;
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(_tr('view_count_dist')),
                      selected: _currentViewType == ImageViewType.countChart,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _currentViewType = ImageViewType.countChart;
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(_tr('view_volume_dist')),
                      selected: _currentViewType == ImageViewType.volumeChart,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _currentViewType = ImageViewType.volumeChart;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8.0, left: 8.0, right: 8.0),
              child: Center(
                child: _selectedImagePath == null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.camera_alt, size: 64, color: Colors.grey),
                          const SizedBox(height: 12),
                          Text(_tr('no_image_hint')),
                        ],
                      )
                    : _isLoading
                        ? const CircularProgressIndicator()
                        : _analysisResult != null
                            ? Builder(
                                builder: (context) {
                                  if (_currentViewType == ImageViewType.countChart ||
                                      _currentViewType == ImageViewType.volumeChart) {
                                    final bins = generateHistogramBins(
                                      _analysisResult!.particles.map((p) => p.equivDiameterUm).toList(),
                                      binCount: 35,
                                    );
                                    final isMobile = MediaQuery.of(context).size.width < 700;
                                    return HistogramChart(
                                      bins: bins,
                                      isVolume: _currentViewType == ImageViewType.volumeChart,
                                      statistics: _analysisResult!.statistics,
                                      totalCount: _analysisResult!.particles.length,
                                      isMobile: isMobile,
                                    );
                                  }

                                  String path;
                                  if (_currentViewType == ImageViewType.calibration &&
                                      _analysisResult!.squareDetectionPath != null) {
                                    path = _analysisResult!.squareDetectionPath!;
                                  } else if (_currentViewType == ImageViewType.mask) {
                                    path = _analysisResult!.binaryMaskPath;
                                  } else {
                                    path = _analysisResult!.annotatedImagePath;
                                  }
                                  return Image.file(
                                    File(path),
                                    key: ValueKey(path),
                                    fit: BoxFit.contain,
                                  );
                                },
                              )
                            : Image.file(
                                File(_selectedImagePath!),
                                fit: BoxFit.contain,
                              ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsArea({required bool isMobile}) {
    if (_analysisResult == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Center(child: Text(_tr('no_analysis_yet'))),
        ),
      );
    }

    final lang = ref.watch(languageProvider);
    final volSuffix = lang == AppLanguage.zh ? '體積' : 'Volume';

    final gridView = GridView.count(
      crossAxisCount: isMobile ? 2 : 3,
      childAspectRatio: isMobile ? 3.0 : 3.5,
      shrinkWrap: isMobile,
      physics: isMobile ? const NeverScrollableScrollPhysics() : null,
      children: [
        StatTile(label: _tr('stat_count'), value: _analysisResult!.statistics['count']?.toStringAsFixed(0) ?? "0"),
        StatTile(label: _tr('stat_mean'), value: "${_analysisResult!.statistics['mean_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: _tr('stat_median'), value: "${_analysisResult!.statistics['median_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: _tr('stat_std'), value: "${_analysisResult!.statistics['std_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dn10", value: "${_analysisResult!.statistics['Dn10_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dn50", value: "${_analysisResult!.statistics['Dn50_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dn90", value: "${_analysisResult!.statistics['Dn90_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dv10 ($volSuffix)", value: "${_analysisResult!.statistics['Dv10_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dv50 ($volSuffix)", value: "${_analysisResult!.statistics['Dv50_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dv90 ($volSuffix)", value: "${_analysisResult!.statistics['Dv90_um']?.toStringAsFixed(1)} μm"),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_tr('stats_title'), 
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            isMobile ? gridView : Expanded(child: gridView),
          ],
        ),
      ),
    );
  }

  Widget _buildControlPanel({required bool isMobile}) {
    return Container(
      color: isMobile ? Colors.transparent : const Color(0xFF1E1E1E),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMobile) ...[
            Text(_tr('controls_title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(),
            const SizedBox(height: 12),
          ],

          // 自動校正開關
          SwitchListTile(
            title: Text(_tr('auto_calibrate')),
            subtitle: Text(_tr('auto_calibrate_subtitle')),
            value: ref.watch(autoCalibrateProvider),
            onChanged: (val) => ref.read(autoCalibrateProvider.notifier).state = val,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),

          // 1. 比例尺或校正框實際邊長
          if (!ref.watch(autoCalibrateProvider))
            _sliderSection(
              title: _tr('manual_scale'),
              value: ref.watch(scaleProvider),
              min: 5.0,
              max: 100.0,
              divisions: 95,
              label: "${ref.watch(scaleProvider).toStringAsFixed(1)} px/mm",
              onChanged: (val) => ref.read(scaleProvider.notifier).state = val,
            )
          else
            _sliderSection(
              title: _tr('square_size'),
              value: ref.watch(squareSizeProvider),
              min: 50.0,
              max: 300.0,
              divisions: 250,
              label: "${ref.watch(squareSizeProvider).toStringAsFixed(1)} mm",
              onChanged: (val) => ref.read(squareSizeProvider.notifier).state = val,
            ),

          // 2. 最小粒徑
          _sliderSection(
            title: _tr('min_diameter'),
            value: ref.watch(minDiameterProvider),
            min: 5.0,
            max: 100.0,
            divisions: 95,
            label: "${ref.watch(minDiameterProvider).toStringAsFixed(0)} μm",
            onChanged: (val) => ref.read(minDiameterProvider.notifier).state = val,
          ),

          // 3. 最大粒徑
          _sliderSection(
            title: _tr('max_diameter'),
            value: ref.watch(maxDiameterProvider),
            min: 500.0,
            max: 3000.0,
            divisions: 50,
            label: "${ref.watch(maxDiameterProvider).toStringAsFixed(0)} μm",
            onChanged: (val) => ref.read(maxDiameterProvider.notifier).state = val,
          ),

          // 4. 最小圓形度
          _sliderSection(
            title: _tr('min_circularity'),
            value: ref.watch(circularityProvider),
            min: 0.1,
            max: 1.0,
            divisions: 18,
            label: ref.watch(circularityProvider).toStringAsFixed(2),
            onChanged: (val) => ref.read(circularityProvider.notifier).state = val,
          ),

          // 5. 分水嶺門檻值
          _sliderSection(
            title: _tr('dist_thresh'),
            value: ref.watch(distThreshProvider),
            min: 0.1,
            max: 2.0,
            divisions: 19,
            label: ref.watch(distThreshProvider).toStringAsFixed(2),
            onChanged: (val) => ref.read(distThreshProvider.notifier).state = val,
          ),

          // 6. 反轉顏色開關
          SwitchListTile(
            title: Text(_tr('invert_color')),
            subtitle: Text(_tr('invert_subtitle')),
            value: ref.watch(invertProvider),
            onChanged: (val) => ref.read(invertProvider.notifier).state = val,
            contentPadding: EdgeInsets.zero,
          ),

          const SizedBox(height: 24),
          
          // 操作按鈕區
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: const Color(0xFF5D4037), // 淺咖啡色
            ),
            onPressed: _loadTestImage,
            icon: const Icon(Icons.casino),
            label: Text(_tr('load_synthetic')),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 50),
                    backgroundColor: const Color(0xFF6F4E37), // 主咖啡色
                  ),
                  onPressed: () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library),
                  label: Text(_tr('select_gallery')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(0, 50),
                    backgroundColor: const Color(0xFF6F4E37), // 主咖啡色
                  ),
                  onPressed: () => _pickImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: Text(_tr('open_camera')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: _selectedImagePath == null ? null : _runAnalysis,
            icon: const Icon(Icons.refresh),
            label: Text(_tr('recalculate')),
          ),
          if (_analysisResult != null) ...[
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Colors.teal.shade700,
                foregroundColor: Colors.white,
              ),
              onPressed: _showSaveProfileDialog,
              icon: const Icon(Icons.save),
              label: Text(_tr('save_profile')),
            ),
          ],
        ],
      ),
    );
  }



  Future<void> _showSaveProfileDialog() async {
    if (_analysisResult == null) return;

    final nowStr = DateTime.now().toString().split('.').first;
    final defaultName = "${_tr('coffee_analysis')} - $nowStr";
    final nameController = TextEditingController(text: defaultName);
    
    String selectedGrinder = "";
    final scaleController = TextEditingController();

    final profiles = ref.read(grindProfileListProvider);
    final previousGrinders = profiles
        .map((p) => p.grinder)
        .where((g) => g.trim().isNotEmpty)
        .toSet()
        .toList();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_tr('save_dialog_title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: _tr('save_field_name'),
                    hintText: _tr('save_field_name_hint'),
                  ),
                ),
                const SizedBox(height: 12),
                Autocomplete<String>(
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    if (textEditingValue.text.isEmpty) {
                      return previousGrinders;
                    }
                    return previousGrinders.where((String option) {
                      return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                    });
                  },
                  fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
                    textController.addListener(() {
                      selectedGrinder = textController.text;
                    });
                    return TextField(
                      controller: textController,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: _tr('save_field_grinder'),
                        hintText: _tr('save_field_grinder_hint'),
                        suffixIcon: const Icon(Icons.arrow_drop_down),
                      ),
                    );
                  },
                  onSelected: (String selection) {
                    selectedGrinder = selection;
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: scaleController,
                  decoration: InputDecoration(
                    labelText: _tr('save_field_scale'),
                    hintText: _tr('save_field_scale_hint'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('btn_cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final grinder = selectedGrinder.trim();
                final scale = scaleController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(_tr('err_empty_name'))),
                  );
                  return;
                }

                final parameters = {
                  'scalePxPerMm': ref.read(scaleProvider),
                  'minDiameterUm': ref.read(minDiameterProvider),
                  'maxDiameterUm': ref.read(maxDiameterProvider),
                  'minCircularity': ref.read(circularityProvider),
                  'distThresh': ref.read(distThreshProvider),
                  'invert': ref.read(invertProvider),
                  'autoCalibrate': ref.read(autoCalibrateProvider),
                  'squareSize': ref.read(squareSizeProvider),
                };

                final equivDiameters = _analysisResult!.particles.map((p) => p.equivDiameterUm).toList();

                await ref.read(grindProfileListProvider.notifier).saveProfile(
                  name: name,
                  grinder: grinder,
                  grindSetting: scale,
                  statistics: _analysisResult!.statistics,
                  parameters: parameters,
                  equivDiameters: equivDiameters,
                  tempAnnotatedPath: _analysisResult!.annotatedImagePath,
                  tempBinaryMaskPath: _analysisResult!.binaryMaskPath,
                  tempSquareDetectionPath: _analysisResult!.squareDetectionPath,
                );

                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_tr('msg_save_success'))),
                );
              },
              child: Text(_tr('btn_save')),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHistoryLayout(bool isMobile) {
    final profiles = ref.watch(grindProfileListProvider);

    if (profiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history_toggle_off, size: 64, color: Colors.grey),
            const SizedBox(height: 12),
            Text(_tr('no_saved_records')),
          ],
        ),
      );
    }

    final lang = ref.watch(languageProvider);
    final grinderLabel = lang == AppLanguage.zh ? "磨豆機" : "Grinder";
    final scaleLabel = lang == AppLanguage.zh ? "刻度" : "Setting";
    final unfilled = lang == AppLanguage.zh ? "未填" : "N/A";
    final timeLabel = lang == AppLanguage.zh ? "時間" : "Time";
    final countLabel = lang == AppLanguage.zh ? "數量" : "Count";
    final pcsUnit = lang == AppLanguage.zh ? " 顆" : "";
    final meanLabel = lang == AppLanguage.zh ? "平均直徑" : "Mean";

    return ListView.builder(
      padding: const EdgeInsets.all(12.0),
      itemCount: profiles.length,
      itemBuilder: (context, index) {
        final profile = profiles[index];
        final dateStr = profile.timestamp.toString().substring(0, 16);
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          color: const Color(0xFF2C2C2C),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            title: Text(
              profile.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                if (profile.grinder.isNotEmpty || profile.grindSetting.isNotEmpty) ...[
                  Text(
                    "$grinderLabel: ${profile.grinder.isEmpty ? unfilled : profile.grinder}  |  $scaleLabel: ${profile.grindSetting.isEmpty ? unfilled : profile.grindSetting}",
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  "$timeLabel: $dateStr  |  $countLabel: ${profile.statistics['count']?.toStringAsFixed(0) ?? '0'}$pcsUnit",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  "$meanLabel: ${profile.statistics['mean_um']?.toStringAsFixed(1) ?? '0'} μm  |  Dv50: ${profile.statistics['Dv50_um']?.toStringAsFixed(1) ?? '0'} μm",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, color: Colors.blueAccent),
                  onPressed: () => _showEditProfileDialog(profile),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                  onPressed: () => _confirmDeleteProfile(profile),
                ),
              ],
            ),
            onTap: () => _viewProfileDetail(profile),
          ),
        );
      },
    );
  }

  Future<void> _showEditProfileDialog(GrindProfile profile) async {
    final nameController = TextEditingController(text: profile.name);
    final scaleController = TextEditingController(text: profile.grindSetting);
    String selectedGrinder = profile.grinder;

    final profiles = ref.read(grindProfileListProvider);
    final previousGrinders = profiles
        .map((p) => p.grinder)
        .where((g) => g.trim().isNotEmpty)
        .toSet()
        .toList();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_tr('edit_dialog_title')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: _tr('save_field_name'),
                  ),
                ),
                const SizedBox(height: 12),
                Autocomplete<String>(
                  initialValue: TextEditingValue(text: profile.grinder),
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    if (textEditingValue.text.isEmpty) {
                      return previousGrinders;
                    }
                    return previousGrinders.where((String option) {
                      return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                    });
                  },
                  fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
                    textController.addListener(() {
                      selectedGrinder = textController.text;
                    });
                    return TextField(
                      controller: textController,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: _tr('save_field_grinder'),
                        suffixIcon: const Icon(Icons.arrow_drop_down),
                      ),
                    );
                  },
                  onSelected: (String selection) {
                    selectedGrinder = selection;
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: scaleController,
                  decoration: InputDecoration(
                    labelText: _tr('save_field_scale'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('btn_cancel')),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final grinder = selectedGrinder.trim();
                final scale = scaleController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(_tr('err_empty_name'))),
                  );
                  return;
                }

                await ref.read(grindProfileListProvider.notifier).editProfile(
                  id: profile.id,
                  name: name,
                  grinder: grinder,
                  grindSetting: scale,
                );

                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_tr('msg_edit_success'))),
                );
              },
              child: Text(_tr('btn_save_changes')),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteProfile(GrindProfile profile) async {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(_tr('delete_dialog_title')),
          content: Text(_tr('delete_confirm_text').replaceAll('{name}', profile.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_tr('btn_cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () async {
                await ref.read(grindProfileListProvider.notifier).deleteProfile(profile.id);
                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(_tr('msg_delete_success'))),
                );
              },
              child: Text(_tr('btn_confirm_delete'), style: const TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _viewProfileDetail(GrindProfile profile) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileDetailPage(profile: profile),
      ),
    );
  }

  Widget _buildAboutLayout() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App Logo or Icon
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(50),
                child: Image.asset(
                  'assets/app_icon_source.png',
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const Icon(
                    Icons.cookie,
                    size: 64,
                    color: Color(0xFF6F4E37),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "Coffee Particle Analyzer",
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _tr('about_subtitle'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade400,
              ),
            ),
            const SizedBox(height: 24),
            
            // Copyright Card
            Card(
              color: const Color(0xFF2C2C2C),
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    _aboutRow(
                      icon: Icons.person,
                      label: _tr('about_authors'),
                      value: "Simon Wu, Simon Signature Coffee Lab",
                    ),
                    const Divider(height: 24, color: Colors.grey),
                    _aboutRow(
                      icon: Icons.assistant,
                      label: _tr('about_ai'),
                      value: "Antigravity with Gemini 3.5",
                    ),
                    const Divider(height: 24, color: Colors.grey),
                    _aboutRow(
                      icon: Icons.info_outline,
                      label: _tr('about_version'),
                      value: "v1.0.0",
                    ),
                    const Divider(height: 24, color: Colors.grey),
                    _aboutRow(
                      icon: Icons.code,
                      label: _tr('about_github'),
                      value: "github.com/simon345wu/particle-analyzer",
                      onTap: () async {
                        final uri = Uri.parse("https://github.com/simon345wu/particle-analyzer");
                        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                          debugPrint("Could not launch $uri");
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            
            // Tech stack badges
            Text(
              "Powered by OpenCV & Flutter",
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _aboutRow({
    required IconData icon,
    required String label,
    required String value,
    VoidCallback? onTap,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.amberAccent, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: onTap,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: onTap != null ? Colors.blue.shade300 : Colors.white,
                    decoration: onTap != null ? TextDecoration.underline : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sliderSection({
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// 區間統計資料結構
class HistogramBin {
  final double startX;
  final double endX;
  final int count;
  final double volumePct;

  HistogramBin({
    required this.startX,
    required this.endX,
    required this.count,
    required this.volumePct,
  });
}

// 顆粒統計直方圖區間與體積繪製方法 (Top-level shared function)
List<HistogramBin> generateHistogramBins(List<double> diameters, {int binCount = 20}) {
  if (diameters.isEmpty) return [];

  double minVal = diameters.reduce(math.min);
  double maxVal = diameters.reduce(math.max);

  if (minVal == maxVal) {
    minVal = minVal - 10;
    maxVal = maxVal + 10;
  }

  final range = maxVal - minVal;
  final binWidth = range / binCount;

  final counts = List<int>.filled(binCount, 0);
  final volumes = List<double>.filled(binCount, 0.0);
  double totalVolume = 0.0;

  for (final d in diameters) {
    final vol = (math.pi / 6.0) * math.pow(d, 3);
    totalVolume += vol;

    int binIndex = ((d - minVal) / binWidth).floor();
    if (binIndex >= binCount) {
      binIndex = binCount - 1;
    } else if (binIndex < 0) {
      binIndex = 0;
    }
    counts[binIndex]++;
    volumes[binIndex] += vol;
  }

  final List<HistogramBin> bins = [];
  for (int i = 0; i < binCount; i++) {
    final startX = minVal + i * binWidth;
    final endX = startX + binWidth;
    final volPct = totalVolume > 0 ? (volumes[i] / totalVolume) * 100.0 : 0.0;
    bins.add(HistogramBin(
      startX: startX,
      endX: endX,
      count: counts[i],
      volumePct: volPct,
    ));
  }
  return bins;
}

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  const StatTile({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
      ],
    );
  }
}

class LegendRow extends StatelessWidget {
  final String label;
  final Color color;
  final bool isMobile;
  const LegendRow({super.key, required this.label, required this.color, this.isMobile = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: isMobile ? 14 : 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: isMobile
                ? [
                    Container(width: 4, height: 1.5, color: color),
                    Container(width: 4, height: 1.5, color: color),
                  ]
                : [
                    Container(width: 5, height: 1.5, color: color),
                    Container(width: 5, height: 1.5, color: color),
                    Container(width: 5, height: 1.5, color: color),
                  ],
          ),
        ),
        SizedBox(width: isMobile ? 4 : 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.black87,
            fontSize: isMobile ? 8.5 : 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class HistogramChart extends ConsumerWidget {
  final List<HistogramBin> bins;
  final bool isVolume;
  final Map<String, double> statistics;
  final int totalCount;
  final bool isMobile;

  const HistogramChart({
    super.key,
    required this.bins,
    required this.isVolume,
    required this.statistics,
    required this.totalCount,
    required this.isMobile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (bins.isEmpty) {
      return Center(child: Text(tr(ref, 'no_data_chart')));
    }

    double maxY = 0;
    for (final bin in bins) {
      final y = isVolume ? bin.volumePct : bin.count.toDouble();
      if (y > maxY) maxY = y;
    }
    if (maxY == 0) maxY = 10;
    maxY = (maxY * 1.15).ceilToDouble();

    // 取得對應的分佈指標
    final double d10 = statistics[isVolume ? 'Dv10_um' : 'Dn10_um'] ?? 0.0;
    final double d50 = statistics[isVolume ? 'Dv50_um' : 'Dn50_um'] ?? 0.0;
    final double d90 = statistics[isVolume ? 'Dv90_um' : 'Dn90_um'] ?? 0.0;

    double minVal = bins.first.startX;
    double maxVal = bins.last.endX;
    double range = maxVal - minVal;
    if (range <= 0) range = 1.0;
    double binWidth = range / bins.length;

    double getX(double diameter) {
      if (binWidth == 0) return 0.0;
      return ((diameter - minVal) / binWidth) - 0.5;
    }

    final xD10 = getX(d10);
    final xD50 = getX(d50);
    final xD90 = getX(d90);

    const barColor = Color(0xFF6F4E37); // 咖啡粉色
    final lang = ref.watch(languageProvider);

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              isVolume
                  ? "${tr(ref, 'chart_title_vol')} (n=$totalCount)"
                  : "${tr(ref, 'chart_title_count')} (n=$totalCount)",
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8.0, right: 8.0),
                  child: BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceAround,
                      maxY: maxY,
                      barTouchData: BarTouchData(
                        enabled: true,
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (_) => Colors.blueGrey.withValues(alpha: 0.85),
                          getTooltipItem: (group, groupIndex, rod, rodIndex) {
                            final bin = bins[group.x.toInt()];
                            final rangeStr = "${bin.startX.toStringAsFixed(0)}-${bin.endX.toStringAsFixed(0)} μm";
                            if (isVolume) {
                              final label = lang == AppLanguage.zh ? "體積比例" : "Volume Pct";
                              return BarTooltipItem(
                                "$rangeStr\n$label: ${rod.toY.toStringAsFixed(1)}%",
                                const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                              );
                            } else {
                              final label = lang == AppLanguage.zh ? "數量" : "Count";
                              final unit = lang == AppLanguage.zh ? " 顆" : "";
                              return BarTooltipItem(
                                "$rangeStr\n$label: ${rod.toY.toInt()}$unit",
                                const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                              );
                            }
                          },
                        ),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        bottomTitles: AxisTitles(
                          axisNameWidget: Text(
                            tr(ref, 'chart_axis_x'),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          axisNameSize: 22,
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            interval: 1.0,
                            getTitlesWidget: (value, meta) {
                              final index = value.toInt();
                              if (index < 0 || index >= bins.length) return const SizedBox.shrink();
                              final bin = bins[index];

                              double? matchedTick;
                              for (final tick in [250.0, 500.0, 750.0, 1000.0, 1250.0, 1500.0, 1750.0, 2000.0]) {
                                if (tick >= bin.startX && tick < bin.endX) {
                                  matchedTick = tick;
                                  break;
                                }
                              }

                              if (matchedTick != null) {
                                return SideTitleWidget(
                                  axisSide: meta.axisSide,
                                  space: 4,
                                  child: Text(
                                    matchedTick.toInt().toString(),
                                    style: const TextStyle(fontSize: 9, color: Colors.black54, fontWeight: FontWeight.w500),
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          ),
                        ),
                        leftTitles: AxisTitles(
                          axisNameWidget: Text(
                            isVolume ? tr(ref, 'chart_axis_y_vol') : tr(ref, 'chart_axis_y_count'),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black87,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          axisNameSize: 22,
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 32,
                            getTitlesWidget: (value, meta) {
                              return SideTitleWidget(
                                axisSide: meta.axisSide,
                                space: 4,
                                child: Text(
                                  value.toStringAsFixed(0),
                                  style: const TextStyle(fontSize: 9, color: Colors.black54, fontWeight: FontWeight.w500),
                                ),
                              );
                            },
                          ),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (value) {
                          return FlLine(
                            color: Colors.grey.shade300,
                            strokeWidth: 1,
                          );
                        },
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(
                          color: Colors.black87,
                          width: 1,
                        ),
                      ),
                      extraLinesData: ExtraLinesData(
                        verticalLines: [
                          VerticalLine(
                            x: xD10,
                            color: Colors.blue,
                            strokeWidth: 1.5,
                            dashArray: [4, 4],
                          ),
                          VerticalLine(
                            x: xD50,
                            color: Colors.green,
                            strokeWidth: 1.5,
                            dashArray: [4, 4],
                          ),
                          VerticalLine(
                            x: xD90,
                            color: Colors.red,
                            strokeWidth: 1.5,
                            dashArray: [4, 4],
                          ),
                        ],
                      ),
                      barGroups: List.generate(bins.length, (index) {
                        final bin = bins[index];
                        final y = isVolume ? bin.volumePct : bin.count.toDouble();
                        return BarChartGroupData(
                          x: index,
                          barRods: [
                            BarChartRodData(
                              toY: y,
                              color: barColor,
                              width: isMobile ? 4 : 10,
                              borderRadius: BorderRadius.zero,
                            ),
                          ],
                        );
                      }),
                    ),
                  ),
                ),
                Positioned(
                  top: isMobile ? 4 : 8,
                  right: isMobile ? 4 : 8,
                  child: Container(
                    padding: isMobile
                        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
                        : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      border: Border.all(color: Colors.grey.shade300, width: 1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LegendRow(
                          label: "D10 = ${d10.toStringAsFixed(0)} um",
                          color: Colors.blue,
                          isMobile: isMobile,
                        ),
                        SizedBox(height: isMobile ? 3 : 6),
                        LegendRow(
                          label: isMobile
                              ? "D50 = ${d50.toStringAsFixed(0)} um"
                              : "${tr(ref, 'legend_median')} = ${d50.toStringAsFixed(0)} um",
                          color: Colors.green,
                          isMobile: isMobile,
                        ),
                        SizedBox(height: isMobile ? 3 : 6),
                        LegendRow(
                          label: "D90 = ${d90.toStringAsFixed(0)} um",
                          color: Colors.red,
                          isMobile: isMobile,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileDetailPage extends ConsumerStatefulWidget {
  final GrindProfile profile;
  const ProfileDetailPage({super.key, required this.profile});

  @override
  ConsumerState<ProfileDetailPage> createState() => _ProfileDetailPageState();
}

class _ProfileDetailPageState extends ConsumerState<ProfileDetailPage> {
  ImageViewType _currentViewType = ImageViewType.particles;

  String _tr(String key) => tr(ref, key);

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final bool isMobile = MediaQuery.of(context).size.width < 700;

    return Scaffold(
      appBar: AppBar(
        title: Text(profile.name),
        backgroundColor: const Color(0xFF3E2723),
      ),
      body: isMobile ? _buildMobileLayout() : _buildDesktopLayout(),
    );
  }

  Widget _buildMobileLayout() {
    return SingleChildScrollView(
      child: Column(
        children: [
          SizedBox(
            height: 380,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: _buildImageArea(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: _buildStatsArea(isMobile: true),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: _buildParamsArea(),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout() {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              children: [
                Expanded(flex: 5, child: _buildImageArea()),
                const SizedBox(height: 8),
                Expanded(flex: 3, child: _buildStatsArea(isMobile: false)),
              ],
            ),
          ),
        ),
        Container(
          width: 320,
          color: const Color(0xFF1E1E1E),
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            child: _buildParamsArea(),
          ),
        ),
      ],
    );
  }

  Widget _buildImageArea() {
    final profile = widget.profile;
    return Card(
      color: Colors.black26,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (profile.localSquareDetectionPath != null) ...[
                    ChoiceChip(
                      label: Text(_tr('view_calibration')),
                      selected: _currentViewType == ImageViewType.calibration,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _currentViewType = ImageViewType.calibration;
                          });
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                  ChoiceChip(
                    label: Text(_tr('view_particles')),
                    selected: _currentViewType == ImageViewType.particles,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _currentViewType = ImageViewType.particles;
                        });
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(_tr('view_mask')),
                    selected: _currentViewType == ImageViewType.mask,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _currentViewType = ImageViewType.mask;
                        });
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(_tr('view_count_dist')),
                    selected: _currentViewType == ImageViewType.countChart,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _currentViewType = ImageViewType.countChart;
                        });
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(_tr('view_volume_dist')),
                    selected: _currentViewType == ImageViewType.volumeChart,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() {
                          _currentViewType = ImageViewType.volumeChart;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8.0, left: 8.0, right: 8.0),
              child: Center(
                child: Builder(
                  builder: (context) {
                    if (_currentViewType == ImageViewType.countChart ||
                        _currentViewType == ImageViewType.volumeChart) {
                      final isMobile = MediaQuery.of(context).size.width < 700;
                      // Generate bins using top level helper
                      double minD = profile.equivDiameters.reduce(math.min);
                      double maxD = profile.equivDiameters.reduce(math.max);
                      if (minD == maxD) {
                        minD -= 10;
                        maxD += 10;
                      }
                      final range = maxD - minD;
                      final binWidth = range / 35;

                      final counts = List<int>.filled(35, 0);
                      final volumes = List<double>.filled(35, 0.0);
                      double totalVolume = 0.0;

                      for (final d in profile.equivDiameters) {
                        final vol = (math.pi / 6.0) * math.pow(d, 3);
                        totalVolume += vol;

                        int binIndex = ((d - minD) / binWidth).floor();
                        if (binIndex >= 35) {
                          binIndex = 34;
                        } else if (binIndex < 0) {
                          binIndex = 0;
                        }
                        counts[binIndex]++;
                        volumes[binIndex] += vol;
                      }

                      final List<HistogramBin> bins = [];
                      for (int i = 0; i < 35; i++) {
                        final startX = minD + i * binWidth;
                        final endX = startX + binWidth;
                        final volPct = totalVolume > 0 ? (volumes[i] / totalVolume) * 100.0 : 0.0;
                        bins.add(HistogramBin(
                          startX: startX,
                          endX: endX,
                          count: counts[i],
                          volumePct: volPct,
                        ));
                      }

                      return HistogramChart(
                        bins: bins,
                        isVolume: _currentViewType == ImageViewType.volumeChart,
                        statistics: profile.statistics,
                        totalCount: profile.statistics['count']?.toInt() ?? 0,
                        isMobile: isMobile,
                      );
                    }

                    String path;
                    if (_currentViewType == ImageViewType.calibration &&
                        profile.localSquareDetectionPath != null) {
                      path = profile.localSquareDetectionPath!;
                    } else if (_currentViewType == ImageViewType.mask) {
                      path = profile.localBinaryMaskPath;
                    } else {
                      path = profile.localAnnotatedImagePath;
                    }
                    return Image.file(
                      File(path),
                      key: ValueKey(path),
                      fit: BoxFit.contain,
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsArea({required bool isMobile}) {
    final profile = widget.profile;
    final lang = ref.watch(languageProvider);
    final volSuffix = lang == AppLanguage.zh ? '體積' : 'Volume';

    final gridView = GridView.count(
      crossAxisCount: isMobile ? 2 : 3,
      childAspectRatio: isMobile ? 3.0 : 3.5,
      shrinkWrap: isMobile,
      physics: isMobile ? const NeverScrollableScrollPhysics() : null,
      children: [
        StatTile(label: _tr('stat_count'), value: profile.statistics['count']?.toStringAsFixed(0) ?? "0"),
        StatTile(label: _tr('stat_mean'), value: "${profile.statistics['mean_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: _tr('stat_median'), value: "${profile.statistics['median_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: _tr('stat_std'), value: "${profile.statistics['std_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dn10", value: "${profile.statistics['Dn10_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dn50", value: "${profile.statistics['Dn50_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dn90", value: "${profile.statistics['Dn90_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dv10 ($volSuffix)", value: "${profile.statistics['Dv10_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dv50 ($volSuffix)", value: "${profile.statistics['Dv50_um']?.toStringAsFixed(1)} μm"),
        StatTile(label: "Dv90 ($volSuffix)", value: "${profile.statistics['Dv90_um']?.toStringAsFixed(1)} μm"),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_tr('stats_title'), 
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            isMobile ? gridView : Expanded(child: gridView),
          ],
        ),
      ),
    );
  }

  Widget _buildParamsArea() {
    final profile = widget.profile;
    final params = profile.parameters;
    final dateStr = profile.timestamp.toString().substring(0, 19);

    return Card(
      color: const Color(0xFF2C2C2C),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_tr('detail_title_params'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Divider(),
            const SizedBox(height: 8),
            _paramRow(_tr('detail_time'), dateStr),
            _paramRow(_tr('detail_grinder'), profile.grinder.isEmpty ? _tr('detail_not_specified') : profile.grinder),
            _paramRow(_tr('detail_scale'), profile.grindSetting.isEmpty ? _tr('detail_not_specified') : profile.grindSetting),
            const SizedBox(height: 12),
            Text(_tr('detail_opencv_params'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
            const SizedBox(height: 6),
            _paramRow(_tr('detail_auto_cal'), (params['autoCalibrate'] ?? false) ? _tr('detail_auto_cal_on') : _tr('detail_auto_cal_off')),
            if (params['autoCalibrate'] == true)
              _paramRow(_tr('detail_square_size'), "${params['squareSize'] ?? 150.0} mm")
            else
              _paramRow(_tr('detail_manual_scale'), "${params['scalePxPerMm'] ?? 25.0} px/mm"),
            _paramRow(_tr('min_diameter'), "${(params['minDiameterUm'] ?? 20.0).toStringAsFixed(0)} μm"),
            _paramRow(_tr('max_diameter'), "${(params['maxDiameterUm'] ?? 2000.0).toStringAsFixed(0)} μm"),
            _paramRow(_tr('min_circularity'), "${params['minCircularity'] ?? 0.5}"),
            _paramRow(_tr('dist_thresh'), "${params['distThresh'] ?? 0.5}"),
            _paramRow(_tr('invert_color'), (params['invert'] ?? false) ? _tr('yes') : _tr('no')),
          ],
        ),
      ),
    );
  }

  Widget _paramRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }
}
