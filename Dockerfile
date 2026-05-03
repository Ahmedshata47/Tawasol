FROM python:3.10-slim

# Set up user with UID 1000 (standard for HF Spaces)
RUN useradd -m -u 1000 user
USER user
ENV PATH="/home/user/.local/bin:$PATH"

WORKDIR /app

# Install system dependencies (ffmpeg is required for Whisper)
USER root
RUN apt-get update && apt-get install -y \
    ffmpeg \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*
USER user

# Copy requirements and install
COPY --chown=user requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application
COPY --chown=user . .

# Ensure the database file exists and is writable by the user
RUN touch tawasol.db && chmod 666 tawasol.db

# HF Spaces uses port 7860 by default
EXPOSE 7860

CMD ["python", "backend.py"]
