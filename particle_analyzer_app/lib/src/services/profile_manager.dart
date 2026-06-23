import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/profile_model.dart';

final grindProfileListProvider = StateNotifierProvider<GrindProfileListNotifier, List<GrindProfile>>((ref) {
  final notifier = GrindProfileListNotifier();
  notifier.loadProfiles();
  return notifier;
});

class GrindProfileListNotifier extends StateNotifier<List<GrindProfile>> {
  GrindProfileListNotifier() : super([]);

  bool _isInitialized = false;
  late Directory _profilesDir;
  late Directory _imagesDir;

  Future<void> _ensureDir() async {
    if (_isInitialized) return;
    final docDir = await getApplicationDocumentsDirectory();
    
    _profilesDir = Directory(p.join(docDir.path, 'profiles'));
    if (!await _profilesDir.exists()) {
      await _profilesDir.create(recursive: true);
    }

    _imagesDir = Directory(p.join(_profilesDir.path, 'images'));
    if (!await _imagesDir.exists()) {
      await _imagesDir.create(recursive: true);
    }

    _isInitialized = true;
  }

  Future<void> loadProfiles() async {
    await _ensureDir();
    try {
      final List<GrindProfile> loaded = [];
      final List<FileSystemEntity> files = _profilesDir.listSync();
      
      for (final file in files) {
        if (file is File && p.extension(file.path) == '.json') {
          try {
            final content = await file.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            loaded.add(GrindProfile.fromJson(json));
          } catch (e) {
            // Log or ignore corrupted JSON profile files
            debugPrint("Failed to parse profile JSON file ${file.path}: $e");
          }
        }
      }
      
      // Sort: Newest first
      loaded.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      state = loaded;
    } catch (e) {
      debugPrint("Failed to load profiles: $e");
    }
  }

  Future<void> saveProfile({
    required String name,
    required String grinder,
    required String grindSetting,
    required Map<String, double> statistics,
    required Map<String, dynamic> parameters,
    required List<double> equivDiameters,
    required String tempAnnotatedPath,
    required String tempBinaryMaskPath,
    String? tempSquareDetectionPath,
  }) async {
    await _ensureDir();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final timestamp = DateTime.now();

    // 1. Copy images to persistent profiles/images/ directory
    final destAnnotated = p.join(_imagesDir.path, '${id}_annotated.jpg');
    final destMask = p.join(_imagesDir.path, '${id}_mask.jpg');
    
    await File(tempAnnotatedPath).copy(destAnnotated);
    await File(tempBinaryMaskPath).copy(destMask);

    String? destSquare;
    if (tempSquareDetectionPath != null && await File(tempSquareDetectionPath).exists()) {
      destSquare = p.join(_imagesDir.path, '${id}_calibration.jpg');
      await File(tempSquareDetectionPath).copy(destSquare);
    }

    // 2. Create the profile object
    final profile = GrindProfile(
      id: id,
      name: name,
      grinder: grinder,
      grindSetting: grindSetting,
      timestamp: timestamp,
      statistics: statistics,
      parameters: parameters,
      equivDiameters: equivDiameters,
      localAnnotatedImagePath: destAnnotated,
      localBinaryMaskPath: destMask,
      localSquareDetectionPath: destSquare,
    );

    // 3. Save JSON file
    final file = File(p.join(_profilesDir.path, '$id.json'));
    await file.writeAsString(jsonEncode(profile.toJson()));

    // 4. Update memory state
    state = [profile, ...state];
  }

  Future<void> editProfile({
    required String id,
    required String name,
    required String grinder,
    required String grindSetting,
  }) async {
    await _ensureDir();
    final index = state.indexWhere((p) => p.id == id);
    if (index == -1) return;

    final updated = state[index].copyWith(
      name: name,
      grinder: grinder,
      grindSetting: grindSetting,
    );

    // Write updated JSON
    final file = File(p.join(_profilesDir.path, '$id.json'));
    await file.writeAsString(jsonEncode(updated.toJson()));

    // Update state
    final list = List<GrindProfile>.from(state);
    list[index] = updated;
    state = list;
  }

  Future<void> deleteProfile(String id) async {
    await _ensureDir();
    final index = state.indexWhere((p) => p.id == id);
    if (index == -1) return;

    final profile = state[index];

    // Delete JSON file
    final file = File(p.join(_profilesDir.path, '$id.json'));
    if (await file.exists()) {
      await file.delete();
    }

    // Delete image files
    final imgAnnotated = File(profile.localAnnotatedImagePath);
    if (await imgAnnotated.exists()) {
      await imgAnnotated.delete();
    }
    
    final imgMask = File(profile.localBinaryMaskPath);
    if (await imgMask.exists()) {
      await imgMask.delete();
    }

    if (profile.localSquareDetectionPath != null) {
      final imgSquare = File(profile.localSquareDetectionPath!);
      if (await imgSquare.exists()) {
        await imgSquare.delete();
      }
    }

    // Update state
    state = state.where((p) => p.id != id).toList();
  }
}
