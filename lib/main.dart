import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:io' show Platform, File;
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:file_selector/file_selector.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tawasol - AI Lecture Assistant',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Tawasol - AI Lecture Assistant'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool isRecording = false;
  String transcript = "Press 'Start' to begin...";
  String summary = "";
  bool isGeneratingSummary = false;
  bool isSaving = false;
  String statusMessage = "Ready";
  List<dynamic> lectures = [];
  String selectedLanguage = 'en';
  bool isUploading = false;
  bool isGeneratingWorkflow = false;
  String mermaidCode = "";

  // Recording variables
  final RecordHelper _audioRecorder = RecordHelper();
  Timer? _recordingTimer;
  int _chunkCount = 0;
  final List<String> _chunkFiles = [];
  bool _isFirstChunk = true;

  // Backend API URL
  late final String apiUrl;

  @override
  void initState() {
    super.initState();
    // Live Hugging Face Space URL
    apiUrl = 'https://a7md47-tawasol-backend.hf.space';

    _fetchLectures();
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _fetchLectures() async {
    try {
      final response = await http.get(Uri.parse('$apiUrl/get_lectures'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          lectures = data['lectures'];
        });
      }
    } catch (e) {
      debugPrint('Error fetching lectures: $e');
    }
  }

  Future<void> _startRecording() async {
    try {
      // Check microphone permission
      final status = await _audioRecorder.hasPermission();
      if (status) {
        setState(() {
          statusMessage = "Starting session...";
        });

        setState(() {
          statusMessage = "Connecting to server...";
        });

        // Reset transcript on server
        await http.post(Uri.parse('$apiUrl/reset'));

        setState(() {
          isRecording = true;
          transcript = "";
          statusMessage = "Recording (5s chunks)...";
          _chunkCount = 0;
        });

        _startChunkRecording();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied')),
          );
        }
      }
    } catch (e) {
      setState(() {
        statusMessage = "Error: $e";
      });
      debugPrint('Error starting recording: $e');
    }
  }

  void _startChunkRecording() async {
    if (!isRecording) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      int currentChunkIndex = _chunkCount++;
      final String path = p.join(directory.path, 'chunk_$currentChunkIndex.wav');

      const config = RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      );

      await _audioRecorder.start(config, path: path);

      // Record for 5 seconds for stability
      _recordingTimer = Timer(const Duration(seconds: 5), () async {
        if (!isRecording) return;

        final String? filePath = await _audioRecorder.stop();
        if (filePath != null) {
          _uploadAudioChunk(filePath, currentChunkIndex);
        }
        _startChunkRecording(); // Start next chunk
      });
    } catch (e) {
      debugPrint('Error in chunk recording: $e');
      _stopRecording();
    }
  }

  Future<void> _uploadAudioChunk(String filePath, int chunkIndex) async {
    try {
      setState(() {
        statusMessage = "Transcribing...";
      });

      var request = http.MultipartRequest('POST', Uri.parse('$apiUrl/transcribe'));
      request.fields['chunk_index'] = chunkIndex.toString();
      request.fields['lang'] = selectedLanguage;
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var data = jsonDecode(responseData);
        if (mounted) {
          setState(() {
            transcript = data['full_transcript'];
            statusMessage = isRecording ? "Recording..." : "Ready";
          });
        }
      } else {
        setState(() {
          statusMessage = "Server error: ${response.statusCode}";
        });
      }

      // Cleanup local file
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Error uploading chunk: $e');
      setState(() {
        statusMessage = "Connection error";
      });
    }
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    final String? filePath = await _audioRecorder.stop();
    if (filePath != null) {
      await _uploadAudioChunk(filePath, _chunkCount++);
    }
    setState(() {
      isRecording = false;
    });
  }

  Future<void> _uploadFile() async {
    if (isRecording || isUploading) return;

    try {
      const XTypeGroup audioGroup = XTypeGroup(
        label: 'Audio Files',
        extensions: <String>['wav', 'mp3', 'm4a', 'aac', 'ogg', 'flac'],
      );
      final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[audioGroup]);

      if (file != null) {
        
        setState(() {
          isUploading = true;
          statusMessage = "Uploading and transcribing...";
          transcript = "Processing uploaded file...";
        });

        var request = http.MultipartRequest('POST', Uri.parse('$apiUrl/transcribe'));
        // Not adding chunk_index so it defaults to -1 on backend and replaces transcript
        request.fields['lang'] = selectedLanguage;
        request.files.add(await http.MultipartFile.fromPath('file', file.path));
        
        var response = await request.send();
        if (response.statusCode == 200) {
          var responseData = await response.stream.bytesToString();
          var data = jsonDecode(responseData);
          if (mounted) {
            setState(() {
              transcript = data['full_transcript'];
              statusMessage = "Ready";
              isUploading = false;
            });
          }
        } else {
          setState(() {
            statusMessage = "Server error: ${response.statusCode}";
            isUploading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error picking or uploading file: $e');
      setState(() {
        statusMessage = "Error uploading file";
        isUploading = false;
      });
    }
  }

  Future<void> _generateSummary() async {
    if (transcript.trim().isEmpty || isGeneratingSummary) return;

    setState(() {
      isGeneratingSummary = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$apiUrl/generate_summary'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"lang": selectedLanguage}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          summary = data['summary'];
        });
        _showSummaryDialog();
      } else {
        final errorData = jsonDecode(response.body);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: ${errorData['error']}')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error generating summary: $e');
    } finally {
      if (mounted) {
        setState(() {
          isGeneratingSummary = false;
        });
      }
    }
  }

  Future<void> _saveLecture() async {
    if (transcript.trim().isEmpty || isSaving) return;

    setState(() {
      isSaving = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$apiUrl/save_lecture'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({}),
      );

      if (response.statusCode == 200) {
        setState(() {
          isSaving = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Lecture saved successfully!')),
          );
        }
        _fetchLectures();
      }
    } catch (e) {
      debugPrint('Error saving lecture: $e');
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
  }

  Future<void> _generateWorkflow() async {
    if (transcript.trim().isEmpty || isGeneratingWorkflow) return;

    setState(() {
      isGeneratingWorkflow = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$apiUrl/generate_workflow'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({"lang": selectedLanguage}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          mermaidCode = data['mermaid'];
        });
        _showWorkflowDialog();
      } else {
        final errorData = jsonDecode(response.body);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: ${errorData['error']}')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error generating workflow: $e');
    } finally {
      if (mounted) {
        setState(() {
          isGeneratingWorkflow = false;
        });
      }
    }
  }

  void _showWorkflowDialog() {
    // Create HTML with Mermaid.js to render the diagram
    final htmlContent = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
  <style>
    body {
      font-family: Arial, sans-serif;
      padding: 20px;
      background-color: #f5f5f5;
      direction: ltr;
    }
    .mermaid {
      background-color: white;
      padding: 20px;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .controls {
      margin-bottom: 15px;
      text-align: center;
    }
    button {
      padding: 8px 16px;
      margin: 5px;
      background-color: #2196F3;
      color: white;
      border: none;
      border-radius: 4px;
      cursor: pointer;
    }
    button:hover {
      background-color: #1976D2;
    }
  </style>
</head>
<body>
  <div class="controls">
    <button onclick="window.print()">Print Diagram</button>
  </div>
  <div class="mermaid">
${mermaidCode.replaceAll('\n', '\n    ')}
  </div>
  <script>
    mermaid.initialize({ 
      startOnLoad: true,
      theme: 'default',
      flowchart: { useMaxWidth: true, htmlLabels: true }
    });
  </script>
</body>
</html>
''';

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.9,
            height: MediaQuery.of(context).size.height * 0.8,
            child: Column(
              children: [
                AppBar(
                  title: const Text('Lecture Workflow'),
                  automaticallyImplyLeading: false,
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.open_in_browser),
                      tooltip: 'Open in Browser',
                      onPressed: () async {
                        final url = Uri.dataFromString(
                          htmlContent,
                          mimeType: 'text/html',
                          encoding: Encoding.getByName('utf-8'),
                        );
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url);
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Expanded(
                  child: WebViewWidget(
                    controller: WebViewController()
                      ..setJavaScriptMode(JavaScriptMode.unrestricted)
                      ..loadHtmlString(htmlContent),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSummaryDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Lecture Summary'),
          content: SingleChildScrollView(
            child: Text(summary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          Row(
            children: [
              const Text('EN', style: TextStyle(fontWeight: FontWeight.bold)),
              Switch(
                value: selectedLanguage == 'ar',
                onChanged: (value) {
                  setState(() {
                    selectedLanguage = value ? 'ar' : 'en';
                  });
                },
                activeColor: Colors.green,
              ),
              const Text('AR', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 16),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Indicator
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.blue.shade700),
                  const SizedBox(width: 8),
                  Text(
                    statusMessage,
                    style: TextStyle(fontSize: 12, color: Colors.blue.shade900, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              flex: 3,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.white,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: SingleChildScrollView(
                    child: Text(
                      transcript.isEmpty ? "Transcription will appear here..." : transcript,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: (isUploading) ? null : (isRecording ? _stopRecording : _startRecording),
                  icon: Icon(isRecording ? Icons.stop_circle : Icons.mic),
                  label: Text(isRecording ? 'Stop' : 'Start'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isRecording ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    elevation: 2,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: (isRecording || isUploading) ? null : _uploadFile,
                  icon: const Icon(Icons.upload_file),
                  label: Text(isUploading ? 'Uploading...' : 'Upload'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    elevation: 2,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: (isGeneratingSummary || transcript.isEmpty || isUploading) ? null : _generateSummary,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(isGeneratingSummary ? 'Analyzing...' : 'Summary'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    elevation: 2,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: (isSaving || transcript.isEmpty || isUploading) ? null : _saveLecture,
                  icon: const Icon(Icons.save),
                  label: Text(isSaving ? 'Saving...' : 'Save'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange.shade800,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    elevation: 2,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: (isGeneratingWorkflow || transcript.isEmpty || isUploading) ? null : _generateWorkflow,
                  icon: const Icon(Icons.account_tree),
                  label: Text(isGeneratingWorkflow ? 'Creating...' : 'Workflow'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    elevation: 2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Lecture History',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 2,
              child: lectures.isEmpty
                  ? const Center(child: Text('No lectures saved yet'))
                  : ListView.builder(
                      itemCount: lectures.length,
                      itemBuilder: (context, index) {
                        final lecture = lectures[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text('Lecture ${lecture['id']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('${lecture['date']}\n${lecture['summary'] != null && lecture['summary'].isNotEmpty ? lecture['summary'].substring(0, lecture['summary'].length.clamp(0, 60)) + '...' : 'No summary'}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.info_outline),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text('Lecture ${lecture['id']}'),
                                    content: SingleChildScrollView(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('Date: ${lecture['date']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                          const Divider(),
                                          const Text('Summary:', style: TextStyle(fontWeight: FontWeight.bold)),
                                          Text(lecture['summary'] ?? 'No summary'),
                                          const Divider(),
                                          const Text('Transcript:', style: TextStyle(fontWeight: FontWeight.bold)),
                                          Text(lecture['transcript']),
                                        ],
                                      ),
                                    ),
                                    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );

  }
}