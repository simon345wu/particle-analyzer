import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:particle_analyzer_app/src/analyzer/opencv_analyzer.dart';

void main() {

  group('OpenCVAnalyzer Tests', () {
    final testImagePath = 'assets/synthetic_particles.jpg';
    late String outDir;

    setUp(() {
      outDir = Directory.systemTemp.createTempSync('particle_test_').path;
    });

    tearDown(() {
      try {
        Directory(outDir).deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Verify test image exists in workspace', () {
      final file = File(testImagePath);
      expect(file.existsSync(), isTrue, reason: 'Test image must exist at $testImagePath');
    });

    test('Run pipeline - Manual Mode', () {
      final result = OpenCVAnalyzer.runPipeline(
        imagePath: testImagePath,
        outDir: outDir,
        scalePxPerMm: 25.0,
        minDiameterUm: 20.0,
        maxDiameterUm: 2000.0,
        minCircularity: 0.5,
        distThresh: 0.5,
        invert: false,
        autoCalibrate: false,
      );

      expect(result.scalePxPerMm, equals(25.0));
      expect(result.particles, isNotEmpty);
      expect(result.statistics['count'], greaterThan(0));
      expect(File(result.annotatedImagePath).existsSync(), isTrue);
      expect(File(result.binaryMaskPath).existsSync(), isTrue);
      expect(result.warpedImagePath, isNull);
      expect(result.squareDetectionPath, isNull);
    });

    test('Run pipeline - Auto Calibration Mode', () {
      final result = OpenCVAnalyzer.runPipeline(
        imagePath: testImagePath,
        outDir: outDir,
        scalePxPerMm: 25.0,
        minDiameterUm: 20.0,
        maxDiameterUm: 2000.0,
        minCircularity: 0.5,
        distThresh: 0.5,
        invert: false,
        autoCalibrate: true,
        squareMm: 150.0,
        targetResolution: 10.0,
      );

      expect(result.scalePxPerMm, equals(10.0));
      expect(result.particles, isNotEmpty);
      expect(result.statistics['count'], greaterThan(0));
      expect(File(result.annotatedImagePath).existsSync(), isTrue);
      expect(File(result.binaryMaskPath).existsSync(), isTrue);
      expect(result.warpedImagePath, isNotNull);
      expect(result.squareDetectionPath, isNotNull);
      expect(File(result.warpedImagePath!).existsSync(), isTrue);
      expect(File(result.squareDetectionPath!).existsSync(), isTrue);
    });
  group('Failure Case: Invalid Calibration Image', () {
    test('Throws exception on image with no square', () {
      // Create a dummy image (e.g., solid gray mat) and save it, then run pipeline on it.
      final grayMat = cv.Mat.zeros(400, 400, cv.MatType.CV_8UC3);
      final invalidPath = '$outDir/invalid.jpg';
      cv.imwrite(invalidPath, grayMat);
      grayMat.dispose();

      expect(
        () => OpenCVAnalyzer.runPipeline(
          imagePath: invalidPath,
          outDir: outDir,
          scalePxPerMm: 25.0,
          minDiameterUm: 20.0,
          maxDiameterUm: 2000.0,
          minCircularity: 0.5,
          distThresh: 0.5,
          invert: false,
          autoCalibrate: true,
        ),
        throwsException,
      );
    });
  });
  });
}
