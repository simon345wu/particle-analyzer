import os

path = r'c:\python_prj\particleAnalyzer\particle_analyzer_app\lib\main.dart'

# Read binary data
with open(path, 'rb') as f:
    data = f.read()

# The target sequence contains the truncated characters and the start of the next line.
# Let's search for a unique segment:
target = b'Text("\xe7\x84\xa1\xe5\xbd\xb1\xe5\x83\x8f\xe8\xb3\x87\xe6\x96\x99\xef\xbc\x8c\xe8\xab\x8b\xe5\xb0\x8e\xe5\x85\xa5\xe5\x92\x96\xe5\x95\xa1\xe7\xb2    final showCalib = ref.read(autoCalibrateProvider) && _analysisResult!.squareDetectionPath != null;'

if target in data:
    print("Found target sequence!")
    # Replacement UTF-8 text in bytes:
    # Text("無影像資料，請選擇或拍攝圖片"),
    #             ],
    #           ),
    #         ),
    #       );
    #     }
    #
    #     final showCalib = ref.read(autoCalibrateProvider) && _analysisResult!.squareDetectionPath != null;
    replacement = (
        b'Text("\xe7\x84\xa1\xe5\xbd\xb1\xe5\x83\x8f\xe8\xb3\x87\xe6\x96\x99\xef\xbc\x8c\xe8\xab\x8b\xe9\x81\xb8\xe6\x93\x87\xe6\x88\x96\xe6\x8b\x8d\xe6\x94\x9d\xe5\x9c\x96\xe7\x89\x87"),\n'
        b'            ],\n'
        b'          ),\n'
        b'        ),\n'
        b'      );\n'
        b'    }\n\n'
        b'    final showCalib = ref.read(autoCalibrateProvider) && _analysisResult!.squareDetectionPath != null;'
    )
    
    new_data = data.replace(target, replacement)
    
    # Also replace enum ImageViewType { calibration, particles, mask }
    enum_target = b'enum ImageViewType { calibration, particles, mask }'
    enum_replacement = b'enum ImageViewType { calibration, particles, mask, countChart, volumeChart }'
    
    if enum_target in new_data:
        print("Found enum sequence!")
        new_data = new_data.replace(enum_target, enum_replacement)
    else:
        print("Enum sequence NOT found!")

    # Write back
    with open(path, 'wb') as f:
        f.write(new_data)
    print("File successfully fixed!")
else:
    print("Target sequence NOT found!")
