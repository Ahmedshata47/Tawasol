from faster_whisper import WhisperModel
import static_ffmpeg
from flask import Flask, request, jsonify
from flask_cors import CORS
import json
import os
import sqlite3
import google.generativeai as genai
from datetime import datetime
import noisereduce as nr
import librosa
import soundfile as sf
import numpy as np

# Initialize FFmpeg paths
static_ffmpeg.add_paths()

# Load Faster Whisper model
print("Loading Faster Whisper model...")
whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
print("Faster Whisper model loaded.")

app = Flask(__name__)
CORS(app)  # Allow Flutter to make requests

# Initialize Gemini
# Reminder: It's a good idea to rotate this key since it was previously exposed!
genai.configure(api_key="AIzaSyCocOJhrHKgE3SByN2GqJXoj7DspSdGRF4")

# Global state for transcript (optional, if you want to keep session-like behavior)
# In-memory storage for the current session
current_transcript = ""
current_summary = ""
session_chunks = {} # Stores chunks by their index to guarantee correct order

# --- Database Setup ---
conn = sqlite3.connect("tawasol.db", check_same_thread=False)
cursor = conn.cursor()
cursor.execute("CREATE TABLE IF NOT EXISTS lectures (id INTEGER PRIMARY KEY, date TEXT, transcript TEXT, summary TEXT)")
conn.commit()

@app.route('/', methods=['GET'])
def health_check():
    return jsonify({"status": "active", "message": "Tawasol API is running"})

# --- API Endpoints ---

@app.route('/transcribe', methods=['POST'])
def transcribe():
    global current_transcript, session_chunks
    
    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400
        
    chunk_index = int(request.form.get('chunk_index', -1))
    lang = request.form.get('lang', 'en')
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400
    
    temp_path = "temp_chunk.wav"
    file.save(temp_path)
    
    print(f"Received audio file: {file.filename}", flush=True)
    
    try:
        # Apply noise reduction
        print("Applying noise reduction...", flush=True)
        audio_data, sr = librosa.load(temp_path, sr=16000)
        reduced_noise_audio = nr.reduce_noise(y=audio_data, sr=sr, prop_decrease=0.8)
        
        # Save cleaned audio
        cleaned_path = "temp_cleaned.wav"
        sf.write(cleaned_path, reduced_noise_audio, sr)
        
        print("Starting transcription...", flush=True)
        # Setting language skips language detection, making it faster.
        segments, info = whisper_model.transcribe(cleaned_path, beam_size=1, language=lang)
        
        results = []
        for segment in segments:
            print(f"Transcribed segment: {segment.text}", flush=True)
            results.append(segment.text)
        
        new_text = "".join(results).strip()
        print(f"Final transcribed text: {new_text}", flush=True)
        
        # Store the chunk in its correct order
        if chunk_index != -1:
            session_chunks[chunk_index] = new_text
            
            # Rebuild the full transcript guaranteeing chronological order
            ordered_transcript = ""
            if session_chunks:
                max_idx = max(session_chunks.keys())
                for i in range(max_idx + 1):
                    if i in session_chunks and session_chunks[i]:
                        ordered_transcript += session_chunks[i] + " "
                        
            current_transcript = ordered_transcript.strip()
        else:
            # If no chunk_index, it's a full file upload. Replace current_transcript.
            current_transcript = new_text
            session_chunks = {} # Reset chunks since we are replacing with a full file
        
        return jsonify({
            "new_text": new_text,
            "full_transcript": current_transcript
        })
    except Exception as e:
        print(f"Transcription ERROR: {str(e)}", flush=True)
        return jsonify({"error": str(e)}), 500
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        if os.path.exists("temp_cleaned.wav"):
            os.remove("temp_cleaned.wav")

@app.route('/reset', methods=['POST'])
def reset_transcript():
    global current_transcript, current_summary, session_chunks
    current_transcript = ""
    current_summary = ""
    session_chunks = {}
    return jsonify({"status": "reset"})

@app.route('/transcript', methods=['GET'])
def get_transcript():
    global current_transcript
    return jsonify({"transcript": current_transcript})

@app.route('/generate_summary', methods=['POST'])
def generate_summary():
    global current_transcript, current_summary
    if not current_transcript.strip():
        return jsonify({"error": "No transcript to summarize"}), 400

    try:
        # Get language from JSON request body, default to English
        req_data = request.get_json(silent=True) or {}
        lang = req_data.get('lang', 'en')
        
        if lang == 'ar':
            prompt = f"""Provide a concise summary and 3 bulleted key points for this lecture transcript in Arabic.
You MUST output your response in valid JSON format exactly like this:
{{
  "summary": "النص الأساسي للملخص...",
  "key_points": ["نقطة 1", "نقطة 2", "نقطة 3"]
}}

Transcript:
{current_transcript}
"""
        else:
            prompt = f"""Provide a concise summary and 3 bulleted key points for this lecture transcript.
You MUST output your response in valid JSON format exactly like this:
{{
  "summary": "The main summary text...",
  "key_points": ["point 1", "point 2", "point 3"]
}}

Transcript:
{current_transcript}
"""
        model = genai.GenerativeModel('gemma-4-26b-a4b-it')
        response = model.generate_content(prompt)
        raw_text = response.text
        
        import json
        
        # Robustly extract the FIRST complete JSON object by counting brackets
        json_str = ""
        start_idx = raw_text.find('{')
        if start_idx != -1:
            count = 0
            for i in range(start_idx, len(raw_text)):
                if raw_text[i] == '{':
                    count += 1
                elif raw_text[i] == '}':
                    count -= 1
                    
                if count == 0:
                    json_str = raw_text[start_idx:i+1]
                    break
        
        if not json_str:
            json_str = raw_text.strip()
            
        try:
            parsed_data = json.loads(json_str)
            formatted_summary = f"{parsed_data.get('summary', '')}\n\nKey Points:\n"
            for pt in parsed_data.get('key_points', []):
                formatted_summary += f"• {pt}\n"
            current_summary = formatted_summary
        except json.JSONDecodeError as e:
            print(f"JSON parse failed: {str(e)}", flush=True)
            print(f"Extracted string was: {json_str}", flush=True)
            current_summary = raw_text
            
        return jsonify({"summary": current_summary})
    except Exception as ex:
        return jsonify({"error": str(ex)}), 500

@app.route('/save_lecture', methods=['POST'])
def save_lecture():
    global current_transcript, current_summary
    if not current_transcript.strip():
        return jsonify({"error": "No transcript to save"}), 400
    
    date_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    cursor.execute("INSERT INTO lectures (date, transcript, summary) VALUES (?, ?, ?)",
                   (date_str, current_transcript, current_summary))
    conn.commit()
    return jsonify({"status": "saved", "id": cursor.lastrowid})

@app.route('/get_lectures', methods=['GET'])
def get_lectures():
    cursor.execute("SELECT id, date, transcript, summary FROM lectures ORDER BY id DESC")
    lectures = []
    for row in cursor.fetchall():
        lectures.append({
            "id": row[0],
            "date": row[1],
            "transcript": row[2],
            "summary": row[3]
        })
    return jsonify({"lectures": lectures})

@app.route('/generate_workflow', methods=['POST'])
def generate_workflow():
    global current_transcript
    if not current_transcript.strip():
        return jsonify({"error": "No transcript to generate workflow"}), 400

    try:
        # Get language from JSON request body, default to English
        req_data = request.get_json(silent=True) or {}
        lang = req_data.get('lang', 'en')
        
        if lang == 'ar':
            prompt = f"""Analyze this lecture transcript and create a Mermaid flowchart diagram showing the workflow/flow of topics and concepts.
The diagram should show how ideas connect and flow through the lecture.

IMPORTANT: Return ONLY the Mermaid code, starting with 'graph TD' or 'flowchart TD'.
Use Arabic text for all nodes and labels.
Keep node IDs in English (like A, B, C) but labels in Arabic.
Make it clear and well-structured.

Example format:
graph TD
    A[المقدمة] --> B[المفهوم الأول]
    B --> C[المفهوم الثاني]
    C --> D[الخلاصة]

Transcript:
{current_transcript}

Return ONLY the Mermaid diagram code, nothing else."""
        else:
            prompt = f"""Analyze this lecture transcript and create a Mermaid flowchart diagram showing the workflow/flow of topics and concepts.
The diagram should show how ideas connect and flow through the lecture.

IMPORTANT: Return ONLY the Mermaid code, starting with 'graph TD' or 'flowchart TD'.
Keep it clear and well-structured.

Example format:
graph TD
    A[Introduction] --> B[First Concept]
    B --> C[Second Concept]
    C --> D[Conclusion]

Transcript:
{current_transcript}

Return ONLY the Mermaid diagram code, nothing else."""

        model = genai.GenerativeModel('gemma-4-26b-a4b-it')
        response = model.generate_content(prompt)
        mermaid_code = response.text.strip()
        
        # Clean up the response - remove markdown code blocks if present
        if mermaid_code.startswith('```'):
            lines = mermaid_code.split('\n')
            # Remove first and last lines if they're markdown code fence
            if lines[0].startswith('```'):
                lines = lines[1:]
            if lines and lines[-1].startswith('```'):
                lines = lines[:-1]
            mermaid_code = '\n'.join(lines)
        
        mermaid_code = mermaid_code.strip()
        
        return jsonify({"mermaid": mermaid_code})
    except Exception as ex:
        print(f"Workflow generation ERROR: {str(ex)}", flush=True)
        return jsonify({"error": str(ex)}), 500

if __name__ == "__main__":
    print("Starting Tawasol AI Lecture Assistant Backend...")
    print("API will be available at http://localhost:7860")
    app.run(host='0.0.0.0', port=7860, debug=True)