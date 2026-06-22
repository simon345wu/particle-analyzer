import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/analyzer/opencv_analyzer.dart';

void main() {
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

// 宣告參數的 StateProvider
final scaleProvider = StateProvider<double>((ref) => 25.0);
final minDiameterProvider = StateProvider<double>((ref) => 20.0);
final maxDiameterProvider = StateProvider<double>((ref) => 2000.0);
final circularityProvider = StateProvider<double>((ref) => 0.5);
final distThreshProvider = StateProvider<double>((ref) => 0.5);
final invertProvider = StateProvider<bool>((ref) => false);

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
      );

      setState(() {
        _analysisResult = result;
        _isLoading = false;
        _statusMessage = "分析完成！偵測到 ${result.particles.length} 顆有效顆粒。";
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = "分析失敗: $e";
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Coffee Grind Particle Analyzer'),
        backgroundColor: const Color(0xFF3E2723),
      ),
      body: Row(
        children: [
          // 左側：影像呈現與結果直方圖
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  // 影像呈現區
                  Expanded(
                    flex: 5,
                    child: Card(
                      color: Colors.black26,
                      child: Center(
                        child: _selectedImagePath == null
                            ? const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.camera_alt, size: 64, color: Colors.grey),
                                  SizedBox(height: 12),
                                  Text("無影像資料，請導入咖啡粉相片"),
                                ],
                              )
                            : _isLoading
                                ? const CircularProgressIndicator()
                                : _analysisResult != null
                                    ? Row(
                                        children: [
                                          Expanded(
                                            child: Image.file(
                                              File(_analysisResult!.annotatedImagePath),
                                              fit: .BoxFit.contain,
                                            ),
                                          ),
                                          const VerticalDivider(),
                                          Expanded(
                                            child: Image.file(
                                              File(_analysisResult!.binaryMaskPath),
                                              fit: BoxFit.contain,
                                            ),
                                          ),
                                        ],
                                      )
                                    : Image.file(
                                        File(_selectedImagePath!),
                                        fit: BoxFit.contain,
                                      ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_statusMessage, style: const TextStyle(color: Colors.amberAccent)),
                  const SizedBox(height: 8),
                  // 下方統計數據板
                  Expanded(
                    flex: 3,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: _analysisResult == null
                            ? const Center(child: Text("尚未進行分析"))
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("統計摘要 (Statistics Summary):", 
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  const Divider(),
                                  Expanded(
                                    child: GridView.count(
                                      crossAxisCount: 3,
                                      childAspectRatio: 3.5,
                                      children: [
                                        _statTile("總數量 (Count)", _analysisResult!.statistics['count']?.toStringAsFixed(0) ?? "0"),
                                        _statTile("平均直徑 (Mean)", "${_analysisResult!.statistics['mean_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("中位直徑 (Median)", "${_analysisResult!.statistics['median_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("標準差 (Std Dev)", "${_analysisResult!.statistics['std_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("Dn10", "${_analysisResult!.statistics['Dn10_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("Dn50", "${_analysisResult!.statistics['Dn50_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("Dn90", "${_analysisResult!.statistics['Dn90_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("Dv10 (體積)", "${_analysisResult!.statistics['Dv10_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("Dv50 (體積)", "${_analysisResult!.statistics['Dv50_um']?.toStringAsFixed(1)} μm"),
                                        _statTile("Dv90 (體積)", "${_analysisResult!.statistics['Dv90_um']?.toStringAsFixed(1)} μm"),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 右側：調參控制台 (GUI 控制板)
          Container(
            width: 320,
            color: const Color(0xFF1E1E1E),
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("參數即時調校控制台", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Divider(),
                  const SizedBox(height: 12),

                  // 1. 比例尺
                  _sliderSection(
                    title: "比例尺 (Scale px/mm)",
                    value: ref.watch(scaleProvider),
                    min: 5.0,
                    max: 100.0,
                    divisions: 95,
                    label: "${ref.watch(scaleProvider).toStringAsFixed(1)} px/mm",
                    onChanged: (val) => ref.read(scaleProvider.notifier).state = val,
                  ),

                  // 2. 最小粒徑
                  _sliderSection(
                    title: "最小粒徑 (Min Diameter)",
                    value: ref.watch(minDiameterProvider),
                    min: 5.0,
                    max: 100.0,
                    divisions: 95,
                    label: "${ref.watch(minDiameterProvider).toStringAsFixed(0)} μm",
                    onChanged: (val) => ref.read(minDiameterProvider.notifier).state = val,
                  ),

                  // 3. 最大粒徑
                  _sliderSection(
                    title: "最大粒徑 (Max Diameter)",
                    value: ref.watch(maxDiameterProvider),
                    min: 500.0,
                    max: 3000.0,
                    divisions: 50,
                    label: "${ref.watch(maxDiameterProvider).toStringAsFixed(0)} μm",
                    onChanged: (val) => ref.read(maxDiameterProvider.notifier).state = val,
                  ),

                  // 4. 最小圓形度
                  _sliderSection(
                    title: "最小圓形度 (Min Circularity)",
                    value: ref.watch(circularityProvider),
                    min: 0.1,
                    max: 1.0,
                    divisions: 18,
                    label: ref.watch(circularityProvider).toStringAsFixed(2),
                    onChanged: (val) => ref.read(circularityProvider.notifier).state = val,
                  ),

                  // 5. 分水嶺門檻值
                  _sliderSection(
                    title: "分水嶺種子門檻 (Dist Thresh)",
                    value: ref.watch(distThreshProvider),
                    min: 0.1,
                    max: 2.0,
                    divisions: 19,
                    label: ref.watch(distThreshProvider).toStringAsFixed(2),
                    onChanged: (val) => ref.read(distThreshProvider.notifier).state = val,
                  ),

                  // 6. 反轉顏色開關
                  SwitchListTile(
                    title: const Text("反轉顏色 (Invert)"),
                    subtitle: const Text("適用於暗色底灑亮粉"),
                    value: ref.watch(invertProvider),
                    onChanged: (val) => ref.read(invertProvider.notifier).state = val,
                  ),

                  const SizedBox(height: 24),
                  
                  // 操作按鈕區
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: const Color(0xFF6F4E37),
                    ),
                    onPressed: () {
                      // 模擬導入一張測試相片路徑
                      // 實務上在此呼叫 ImagePicker 取相簿或開相機
                      setState(() {
                        _selectedImagePath = "c:/python_prj/particleAnalyzer/synthetic_particles.jpg";
                      });
                      _runAnalysis();
                    },
                    icon: const Icon(Icons.photo_library),
                    label: const Text("載入測試影像"),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: _selectedImagePath == null ? null : _runAnalysis,
                    icon: const Icon(Icons.refresh),
                    label: const Text("重新計算"),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statTile(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
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
            Text(title, style: const TextStyle(fontSize: 14)),
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
