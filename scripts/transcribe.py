#!/usr/bin/env python3
import os
import sys
import json
import argparse
import time
import logging
import numpy as np
from pathlib import Path

# Configure Logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def _get_language_name(code):
    """Get full language name from language code."""
    lang_names = {
        "en": "English",
        "zh": "Chinese",
        "zh-cn": "Chinese (Simplified)",
        "zh-tw": "Chinese (Traditional)",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
        "ja": "Japanese",
        "ko": "Korean",
        "ru": "Russian",
        "ar": "Arabic",
        "hi": "Hindi",
        # MLX-Whisper non-standard codes
        "nn": "Chinese (Mandarin)",
        "cmn": "Chinese (Mandarin)"
    }
    return lang_names.get(code, f"{code} (Unknown)")

def load_screenshots_metadata(audio_path):
    """
    Load screenshot metadata from screenshots_metadata.json.

    Args:
        audio_path: Path to audio file (used to locate metadata.json in same directory)

    Returns:
        List of screenshot metadata dicts with timestamp, path, ocrText, names
    """
    audio_dir = Path(audio_path).parent
    metadata_path = audio_dir / "screenshots_metadata.json"

    if not metadata_path.exists():
        logger.info("📸 No screenshots_metadata.json found")
        return []

    try:
        with open(metadata_path, 'r') as f:
            data = json.load(f)

        logger.info(f"📸 Loaded {len(data)} screenshots from metadata")
        return data
    except Exception as e:
        logger.warning(f"Failed to load screenshots_metadata.json: {e}")
        return []

def match_speaker_names_from_ocr(segments, screenshots_metadata, window_sec=5.0):
    """
    Match speaker names from OCR text to speaker IDs using fuzzy matching.

    Args:
        segments: List of ASR segments with 'speaker', 'start', 'end' (in milliseconds)
        screenshots_metadata: List of screenshot metadata with timestamp, ocrText, names
        window_sec: Time window to look for screenshots around each segment

    Returns:
        Dict mapping speaker_id to name
    """
    from collections import defaultdict
    import re

    # Count name occurrences for each speaker
    speaker_name_votes = defaultdict(lambda: defaultdict(int))

    for seg in segments:
        speaker = seg.get('speaker', '')
        start_sec = seg.get('start', 0) / 1000.0
        end_sec = seg.get('end', 0) / 1000.0

        # Find screenshots in time window
        for shot in screenshots_metadata:
            shot_time = shot.get('timestamp', 0)
            # Check if screenshot is within time window
            if abs(shot_time - start_sec) <= window_sec or abs(shot_time - end_sec) <= window_sec:
                # Extract names from OCR text
                names = shot.get('names', [])
                for name in names:
                    if len(name) > 2:  # Filter out very short names
                        speaker_name_votes[speaker][name] += 1

    # Select most common name for each speaker
    speaker_names = {}
    for speaker, name_counts in speaker_name_votes.items():
        if name_counts:
            most_common = max(name_counts.items(), key=lambda x: x[1])
            if most_common[1] >= 2:  # Require at least 2 occurrences
                speaker_names[speaker] = most_common[0]
                logger.info(f"👤 Matched {speaker} → {most_common[0]} ({most_common[1]} votes)")

    return speaker_names

def check_environment(require_whisperx=False, require_mlx=False):
    """Check if required dependencies are installed."""
    import torch

    if require_mlx:
        try:
            import mlx_whisper
        except ImportError:
            logger.error("MLX-Whisper not installed. Install: pip install mlx-whisper")
            sys.exit(1)

    if not require_whisperx and not require_mlx:
        # Only check FunASR dependencies if not using WhisperX or MLX
        try:
            import funasr
            import modelscope
        except ImportError as e:
            logger.error(f"Missing dependency: {e}")
            logger.error("Please install dependencies: pip install torch torchaudio funasr modelscope")
            sys.exit(1)

    if require_whisperx:
        try:
            import whisperx
        except ImportError:
            logger.error("WhisperX not installed. Install: pip install whisperx")
            sys.exit(1)

def aggressive_gating(system_audio_path, mic_audio_path, threshold=0.05, margin=0.1):
    """
    Apply aggressive gating to eliminate echo from mic audio.

    When system audio (remote speaker) is active, mute the mic to prevent echo.
    This prevents ASR from transcribing the same speech twice.

    Args:
        system_audio_path: Path to system audio file (remote speaker)
        mic_audio_path: Path to mic audio file (local mic + echo)
        threshold: Energy threshold for gating (0.05 = -26dB)
        margin: Time margin in seconds to add before/after system audio (0.1s = 100ms)

    Returns:
        Clean mic audio (with echo gated out)
    """
    try:
        import librosa
    except ImportError:
        logger.error("librosa not installed. Install: pip install librosa")
        logger.error("Falling back to simple merge without gating")
        return None

    logger.info(f"🎛️ Applying aggressive gating (threshold={threshold}, margin={margin}s)")

    # Load audio files with error handling
    try:
        system_audio, sr_sys = librosa.load(system_audio_path, sr=None)
    except Exception as e:
        logger.warn(f"⚠️ Failed to load system audio: {e}")
        logger.warn("Falling back to mic-only transcription")
        return None

    try:
        mic_audio, sr_mic = librosa.load(mic_audio_path, sr=None)
    except Exception as e:
        logger.error(f"❌ Failed to load mic audio: {e}")
        return None

    # Resample to same sample rate if needed
    if sr_sys != sr_mic:
        target_sr = max(sr_sys, sr_mic)
        system_audio = librosa.resample(system_audio, orig_sr=sr_sys, target_sr=target_sr)
        mic_audio = librosa.resample(mic_audio, orig_sr=sr_mic, target_sr=target_sr)
        sr = target_sr
    else:
        sr = sr_sys

    # Calculate energy envelope (RMS)
    frame_length = int(0.025 * sr)  # 25ms frames
    hop_length = int(0.010 * sr)    # 10ms hop

    system_energy = librosa.feature.rms(y=system_audio, frame_length=frame_length, hop_length=hop_length)[0]

    # Convert frame indices to sample indices
    time_resolution = hop_length / sr

    # Create mask: 1 where mic is active, 0 where system is active
    # Expand system active regions by margin on both sides
    margin_frames = int(margin / time_resolution)

    mask = np.ones(len(mic_audio))

    # Find frames where system energy exceeds threshold
    system_active = system_energy > threshold

    if np.any(system_active):
        # Expand the mask by margin frames (dilation)
        import scipy.ndimage as ndimage
        system_active_expanded = ndimage.binary_dilation(
            system_active.astype(np.int8),
            structure=np.ones(2 * margin_frames + 1)
        ).astype(bool)

        # Convert frame indices to sample indices
        for i, is_active in enumerate(system_active_expanded):
            if is_active:
                start_sample = int(i * hop_length)
                end_sample = min(start_sample + hop_length, len(mask))
                mask[start_sample:end_sample] = 0

    # Apply mask to mic audio
    clean_mic = mic_audio * mask

    # Calculate statistics
    gated_ratio = 1 - np.sum(mask) / len(mask)
    logger.info(f"📊 Gating statistics: {gated_ratio*100:.1f}% of mic audio gated")

    return clean_mic, sr

def transcribe_with_whisperx(audio_path, language="en", device="mps"):
    """
    Transcribe audio using WhisperX with speaker diarization.

    Args:
        audio_path: Path to audio file (system audio recommended for clarity)
        language: Language code ("en", "zh", etc.)
        device: Device to use ("mps", "cpu", "cuda")

    Returns:
        Dictionary with sentence_info in same format as FunASR
    """
    import whisperx

    # Note: faster_whisper (used by whisperX) doesn't support MPS
    # We need to use CPU for macOS
    if device == "mps":
        logger.info("⚠️  MPS not supported by faster_whisper, using CPU")
        device = "cpu"

    # Use float32 for CPU compatibility
    compute_type = "float16" if device != "cpu" else "float32"

    logger.info(f"🎙️ Using WhisperX (language: {language}, device: {device})")

    # 1. Load audio
    audio = whisperx.load_audio(audio_path)

    # 2. Transcribe with Whisper
    logger.info("📝 Transcribing with Whisper...")
    model = whisperx.load_model("large-v3", device=device, compute_type=compute_type)

    result = model.transcribe(
        audio,
        language=language,
        batch_size=16 if device == "mps" else 32,
    )

    # 3. Align with whisperX (word-level timestamps)
    logger.info("🔗 Aligning timestamps...")
    model_a, metadata = whisperx.load_align_model(
        language_code=result["language"],
        device=device
    )
    result = whisperx.align(
        result["segments"],
        model_a,
        metadata,
        audio,
        device=device
    )

    # 4. Speaker diarization
    logger.info("👥 Running speaker diarization...")
    diarize_model = whisperx.DiarizationPipeline(
        use_auth_token=None,
        device=device
    )

    # Assign speaker labels
    result = whisperx.assign_word_speakers_diarization(
        diarize_model,
        result,
        audio
    )

    # 5. Convert to FunASR format (without word-level timestamps)
    sentences = []
    for seg in result["segments"]:
        sentences.append({
            "text": seg["text"].strip(),
            "start": int(seg["start"] * 1000),  # Convert to ms
            "end": int(seg["end"] * 1000),
            "spk": 0 if seg["speaker"] == "SPEAKER_00" else 1,
            "speaker": "Remote" if seg["speaker"] == "SPEAKER_00" else "Local"
        })

    logger.info(f"✅ WhisperX completed: {len(sentences)} segments")

    return {"sentence_info": sentences}

def transcribe_with_mlx(audio_path, language="en", model="mlx-community/whisper-large-v3-mlx"):
    """
    Transcribe audio using MLX-Whisper with basic speaker detection.

    Args:
        audio_path: Path to audio file
        language: Language code ("en", "zh", "auto", etc.) - "auto" for auto-detection
        model: MLX-Whisper model path

    Returns:
        Dictionary with sentence_info in same format as FunASR
    """
    from mlx_whisper import transcribe

    # Auto-detect language if specified
    use_language = None if language == "auto" else language
    logger.info(f"🎙️ Using MLX-Whisper (model: {model}, language: {language if language != 'auto' else 'auto-detect'})")

    # Transcribe with word timestamps
    result = transcribe(
        audio_path,
        path_or_hf_repo=model,
        language=use_language,  # None enables auto-detection
        word_timestamps=True
    )

    # Log detected language if auto-detected
    if language == "auto" and "language" in result:
        detected_lang = result["language"]
        logger.info(f"🌐 Detected language: {detected_lang} ({_get_language_name(detected_lang)})")

    # Convert to FunASR format with basic speaker labels (no timestamps)
    sentences = []
    for i, seg in enumerate(result.get("segments", [])):
        # Basic speaker detection: alternate between speakers
        # For proper diarization, use pyannote (requires network access)
        speaker_label = "SPEAKER_00" if i % 2 == 0 else "SPEAKER_01"
        speaker_name = "Remote" if i % 2 == 0 else "Local"

        sentences.append({
            "text": seg["text"].strip(),
            "start": int(seg["start"] * 1000),
            "end": int(seg["end"] * 1000),
            "spk": 0 if i % 2 == 0 else 1,
            "speaker": speaker_name
        })

    logger.info(f"✅ MLX-Whisper completed: {len(sentences)} segments")

    return {"sentence_info": sentences}

def transcribe_dual_track_mlx(mic_path, sys_path, language="en", model="mlx-community/whisper-large-v3-mlx"):
    """
    Transcribe dual-track audio using MLX-Whisper.

    For English meetings, transcribe system audio only (cleaner).
    """
    logger.info("🎙️ Using MLX-Whisper for dual-track transcription")

    # Transcribe system audio (primary, cleaner)
    logger.info("📝 Transcribing system audio...")
    result = transcribe_with_mlx(sys_path, language=language, model=model)

    return result

def add_pyannote_speakers(mlx_result, audio_path, screenshots_metadata=None):
    """
    Add pyannote Community-1 speaker labels to MLX-Whisper transcription.

    Args:
        mlx_result: MLX-Whisper result dict with sentence_info
        audio_path: Path to audio file for diarization
        screenshots_metadata: Optional list of screenshot metadata with OCR names

    Returns:
        Updated result with speaker labels from pyannote and OCR names
    """
    from pyannote.audio import Pipeline
    import librosa
    import torch

    logger.info("🎯 Running pyannote Community-1 diarization...")

    try:
        # Load pipeline
        pipeline = Pipeline.from_pretrained('pyannote/speaker-diarization-community-1')

        # Load audio
        waveform, sample_rate = librosa.load(audio_path, sr=16000, mono=True)
        audio_dict = {
            'waveform': torch.from_numpy(waveform).unsqueeze(0),
            'sample_rate': sample_rate
        }

        # Run diarization
        out = pipeline(audio_dict)
        sd = out.speaker_diarization

        # Get speakers and segments
        speakers = list(sd.labels())
        logger.info(f"pyannote detected {len(speakers)} speakers: {speakers}")

        # Build a list of speaker segments for faster lookup
        speaker_segments = []
        for segment, track in sd.itertracks(yield_label=False):
            speaker = track.name if hasattr(track, 'name') else "SPEAKER_00"
            speaker_segments.append({
                'start': segment.start,
                'end': segment.end,
                'speaker': speaker
            })

        # Sort by start time
        speaker_segments.sort(key=lambda x: x['start'])

        # Update MLX-Whisper result with speaker labels
        sentences = mlx_result.get('sentence_info', [])
        for i, sent in enumerate(sentences):
            start_ms = sent.get('start', 0)
            end_ms = sent.get('end', 0)
            start_sec = start_ms / 1000.0
            end_sec = end_ms / 1000.0  # Calculate end time in seconds
            mid_sec = (start_ms + end_ms) / 2000.0  # Use midpoint of segment

            # Find closest speaker segment (within 10 seconds)
            speaker = None
            min_distance = float('inf')
            for seg in speaker_segments:
                # Check for overlap
                if seg['end'] > start_sec and seg['start'] < end_sec:
                    speaker = seg['speaker']
                    break

                # Check distance to segment
                distance = min(abs(mid_sec - seg['start']), abs(mid_sec - seg['end']))
                if distance < 10.0 and distance < min_distance:
                    min_distance = distance
                    speaker = seg['speaker']

            # Fall back to alternating speakers if no speaker found
            if speaker is None:
                speaker = "SPEAKER_00" if i % 2 == 0 else "SPEAKER_01"

            # Update speaker
            sent['speaker'] = speaker
            # Also update spk based on speaker name
            sent['spk'] = 0 if "SPEAKER_00" in speaker else 1

        logger.info(f"✅ Added pyannote speakers to {len(sentences)} segments")

        # Match OCR names to speaker IDs
        if screenshots_metadata:
            logger.info("🔍 Matching OCR names to speaker IDs...")
            speaker_names = match_speaker_names_from_ocr(sentences, screenshots_metadata)

            # Apply name mapping
            for sent in sentences:
                speaker = sent.get('speaker', '')
                if speaker in speaker_names:
                    sent['speaker_name'] = speaker_names[speaker]

            logger.info(f"✅ Named {len(speaker_names)} speakers from OCR")

        return mlx_result

    except Exception as e:
        logger.warning(f"⚠️ pyannote diarization failed: {e}")
        logger.info("Using basic alternating speaker labels instead")
        return mlx_result

def transcribe_dual_track_mlx_with_diarization(mic_path, sys_path, language="en", model="mlx-community/whisper-large-v3-mlx"):
    """
    Transcribe dual-track audio using MLX-Whisper with aggressive gating.

    Strategy:
    1. Apply aggressive gating to mic audio (remove echo from system audio)
    2. Transcribe sys.m4a (remote speaker)
    3. Transcribe clean_mic.m4a (local speaker, echo removed)
    4. Combine transcripts
    5. Apply speaker diarization with OCR name matching

    Args:
        mic_path: Path to microphone audio
        sys_path: Path to system audio
        language: Language code ('en' or 'zh')
        model: MLX-Whisper model name

    Returns:
        Transcription result with speaker labels and OCR names
    """
    logger.info("🎙️ Using MLX-Whisper + aggressive gating for dual-track transcription")

    # 1. Apply aggressive gating to remove echo from mic
    gated_result = aggressive_gating(sys_path, mic_path)
    if gated_result is None:
        logger.warn("⚠️ Gating failed or system audio unavailable, falling back to mic-only transcription")
        screenshots_metadata = load_screenshots_metadata(mic_path)
        result = transcribe_with_mlx(mic_path, language=language, model=model)
        result = add_pyannote_speakers(result, mic_path, screenshots_metadata=screenshots_metadata)
        # Mark all segments as from mic track
        if 'sentence_info' in result:
            for sent in result['sentence_info']:
                sent['track'] = 'mic'
        return result

    clean_mic, sr = gated_result

    # 2. Save clean_mic to temp file
    import tempfile
    import soundfile as sf
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_mic:
        sf.write(tmp_mic.name, clean_mic, sr)
        clean_mic_path = tmp_mic.name

    try:
        # 3. Transcribe system audio (remote speaker)
        logger.info("📝 Transcribing system audio (remote speaker)...")
        sys_result = transcribe_with_mlx(sys_path, language=language, model=model)

        # 4. Transcribe clean mic audio (local speaker)
        logger.info("📝 Transcribing clean mic audio (local speaker)...")
        mic_result = transcribe_with_mlx(clean_mic_path, language=language, model=model)

        # 5. Add track source labels
        if 'sentence_info' in sys_result:
            for sent in sys_result['sentence_info']:
                sent['track'] = 'sys'
        if 'sentence_info' in mic_result:
            for sent in mic_result['sentence_info']:
                sent['track'] = 'mic'

        # 6. Combine transcripts
        result = combine_transcripts(sys_result, mic_result)

        # 7. Load screenshots and apply speaker diarization with OCR matching
        screenshots_metadata = load_screenshots_metadata(mic_path)
        result = add_pyannote_speakers(result, mic_path, screenshots_metadata=screenshots_metadata)

        return result

    finally:
        # Clean up temp file
        import os
        if os.path.exists(clean_mic_path):
            os.remove(clean_mic_path)

def transcribe_dual_track_whisperx(mic_path, sys_path, device="mps", language="en"):
    """
    Transcribe dual-track audio using WhisperX with aggressive gating.

    Strategy:
    1. Apply aggressive gating to mic audio (remove echo from system audio)
    2. Transcribe sys.m4a (remote speaker)
    3. Transcribe clean_mic.m4a (local speaker, echo removed)
    4. Combine transcripts
    5. Apply speaker diarization (WhisperX built-in)

    Args:
        mic_path: Path to microphone audio
        sys_path: Path to system audio
        device: Device to use ('mps', 'cpu', 'cuda')
        language: Language code ('en', 'zh', etc.)

    Returns:
        Transcription result with speaker labels
    """
    logger.info("🎙️ Using WhisperX + aggressive gating for dual-track transcription")

    # 1. Apply aggressive gating to remove echo from mic
    gated_result = aggressive_gating(sys_path, mic_path)
    if gated_result is None:
        logger.warn("⚠️ Gating failed or system audio unavailable, falling back to mic-only transcription")
        result = transcribe_with_whisperx(mic_path, language=language, device=device)
        # Mark all segments as from mic track
        if 'sentence_info' in result:
            for sent in result['sentence_info']:
                sent['track'] = 'mic'
        return result

    clean_mic, sr = gated_result

    # 2. Save clean_mic to temp file
    import tempfile
    import soundfile as sf
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_mic:
        sf.write(tmp_mic.name, clean_mic, sr)
        clean_mic_path = tmp_mic.name

    try:
        # 3. Transcribe system audio (remote speaker)
        logger.info("📝 Transcribing system audio (remote speaker)...")
        sys_result = transcribe_with_whisperx(sys_path, language=language, device=device)

        # 4. Transcribe clean mic audio (local speaker)
        logger.info("📝 Transcribing clean mic audio (local speaker)...")
        mic_result = transcribe_with_whisperx(clean_mic_path, language=language, device=device)

        # 5. Add track source labels
        if 'sentence_info' in sys_result:
            for sent in sys_result['sentence_info']:
                sent['track'] = 'sys'
        if 'sentence_info' in mic_result:
            for sent in mic_result['sentence_info']:
                sent['track'] = 'mic'

        # 6. Combine transcripts
        result = combine_transcripts(sys_result, mic_result)

        return result

    finally:
        # Clean up temp file
        import os
        if os.path.exists(clean_mic_path):
            os.remove(clean_mic_path)

def transcribe_dual_track(mic_path, sys_path, model, device):
    """
    Transcribe dual-track audio with aggressive gating.

    Returns:
        Combined transcription with speaker labels
    """
    # Apply aggressive gating
    gated_result = aggressive_gating(sys_path, mic_path)

    if gated_result is not None:
        clean_mic, sr = gated_result
        # Save clean mic to temp file
        import tempfile
        import soundfile as sf
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_mic:
            sf.write(tmp_mic.name, clean_mic, sr)
            clean_mic_path = tmp_mic.name

        logger.info("✅ Aggressive gating applied successfully")
    else:
        logger.warning("⚠️ Gating failed, using original audio")
        clean_mic_path = mic_path

    # Transcribe system audio (remote speaker)
    logger.info(f"🎤 Transcribing system audio (remote)...")
    sys_result = model.generate(
        input=sys_path,
        batch_size_s=300,
    )

    # Transcribe clean mic audio (local speaker)
    logger.info(f"🎤 Transcribing mic audio (local, gated)...")
    mic_result = model.generate(
        input=clean_mic_path,
        batch_size_s=300,
    )

    # Clean up temp file
    if gated_result:
        os.unlink(clean_mic_path)

    # Merge results with speaker labels
    sys_transcript = sys_result[0] if isinstance(sys_result, list) and len(sys_result) > 0 else {}
    mic_transcript = mic_result[0] if isinstance(mic_result, list) and len(mic_result) > 0 else {}

    # Add track source (preserve original spk from FunASR Cam++)
    if 'sentence_info' in sys_transcript:
        for sent in sys_transcript['sentence_info']:
            sent['track'] = 'sys'  # Track source, not overriding 'spk'

    if 'sentence_info' in mic_transcript:
        for sent in mic_transcript['sentence_info']:
            sent['track'] = 'mic'  # Track source, not overriding 'spk'

    # Combine transcripts by timestamp
    combined = combine_transcripts(sys_transcript, mic_transcript)

    # Remove timestamp arrays from all sentences (FunASR includes them by default)
    if 'sentence_info' in combined:
        for sent in combined['sentence_info']:
            if 'timestamp' in sent:
                del sent['timestamp']

    return combined

def combine_transcripts(sys_transcript, mic_transcript):
    """Combine two transcripts and sort by timestamp."""
    all_sentences = []

    if 'sentence_info' in sys_transcript:
        all_sentences.extend(sys_transcript['sentence_info'])

    if 'sentence_info' in mic_transcript:
        all_sentences.extend(mic_transcript['sentence_info'])

    # Sort by start time
    all_sentences.sort(key=lambda x: x.get('start', 0))

    return {'sentence_info': all_sentences}

def get_funasr_model(device="mps", language="zh"):
    """
    Load FunASR model with appropriate language configuration.

    Args:
        device: Device to use (mps, cpu, cuda)
        language: Language code ("zh" for Chinese, "en" for English)
    """
    from funasr import AutoModel

    if language == "en":
        # English model from ModelScope
        # NOTE: English model doesn't support timestamps, so speaker diarization is disabled
        model_name = "iic/speech_paraformer_asr-en-16k-vocab4199-pytorch"
        logger.info(f"🇬🇧 Using English Paraformer model: {model_name}")
        logger.warning("⚠️  English model doesn't support speaker diarization (no timestamps)")

        model = AutoModel(
            model=model_name,
            vad_model="fsmn-vad",
            punc_model="ct-punc",
            # spk_model="cam++",  # Disabled: English model doesn't support timestamps
            device=device,
            disable_update=True,
            log_level="ERROR"
        )
    else:
        # Chinese model (default) - full pipeline with speaker diarization
        model_name = "paraformer-zh"
        logger.info(f"🇨🇳 Using Chinese Paraformer model: {model_name}")

        model = AutoModel(
            model=model_name,
            vad_model="fsmn-vad",
            punc_model="ct-punc",
            spk_model="cam++",
            device=device,
            disable_update=True,
            log_level="ERROR"
        )

    return model

def main():
    parser = argparse.ArgumentParser(description="iKit ASR Transcriber - FunASR + WhisperX + MLX")
    parser.add_argument("input_files", nargs='+', help="Path(s) to audio file(s)")
    parser.add_argument("--output", "-o", help="Path to save the output JSON", default=None)
    parser.add_argument("--device", "-d", help="Device to use (mps, cpu, cuda)", default=None)
    parser.add_argument("--engine", "-e", choices=["funasr", "whisperx", "mlx"], default="funasr",
                        help="ASR engine: funasr (Chinese), whisperx (English), mlx (English, Apple Silicon optimized)")
    parser.add_argument("--language", "-l", default="auto",
                        help="Language code (zh, en, auto). Default: auto (auto-detect)")
    parser.add_argument("--no-gating", action="store_true", help="Disable aggressive gating (FunASR only)")
    parser.add_argument("--mlx-model", default="mlx-community/whisper-large-v3-mlx",
                        help="MLX-Whisper model path (default: mlx-community/whisper-large-v3-mlx)")
    args = parser.parse_args()

    # Check dependencies
    check_environment(require_whisperx=(args.engine == "whisperx"), require_mlx=(args.engine == "mlx"))

    import torch

    # 1. Device Selection
    if args.device:
        device = args.device
    else:
        if torch.backends.mps.is_available():
            device = "mps"
        elif torch.cuda.is_available():
            device = "cuda"
        else:
            device = "cpu"

    logger.info(f"⚡️ Inference Device: {device.upper()}")
    logger.info(f"🔧 ASR Engine: {args.engine.upper()}")
    logger.info(f"🌐 Language: {args.language}")

    # 2. Determine input mode
    input_files = args.input_files

    if len(input_files) == 2:
        # Dual-track mode
        mic_path, sys_path = input_files
        logger.info(f"🎛️ Dual-track mode: mic={Path(mic_path).name}, sys={Path(sys_path).name}")

        if args.engine == "mlx":
            # Use MLX-Whisper + pyannote (recommended for English on Apple Silicon)
            result = transcribe_dual_track_mlx_with_diarization(mic_path, sys_path, language=args.language, model=args.mlx_model)
        elif args.engine == "whisperx":
            # Use WhisperX (recommended for English)
            result = transcribe_dual_track_whisperx(mic_path, sys_path, device=device, language=args.language)
        else:
            # Use FunASR with appropriate language model
            start_load = time.time()
            model = get_funasr_model(device=device, language=args.language)
            logger.info(f"✅ FunASR models loaded in {time.time() - start_load:.2f}s")

            if args.no_gating:
                logger.warning("⚠️ Gating disabled - echo may cause duplicate transcriptions")
                sys_result = model.generate(input=sys_path, batch_size_s=300)
                mic_result = model.generate(input=mic_path, batch_size_s=300)
                sys_result = sys_result[0] if isinstance(sys_result, list) else {}
                mic_result = mic_result[0] if isinstance(mic_result, list) else {}
                # Add track source (preserve original spk from FunASR Cam++)
                if 'sentence_info' in sys_result:
                    for sent in sys_result['sentence_info']:
                        sent['track'] = 'sys'
                if 'sentence_info' in mic_result:
                    for sent in mic_result['sentence_info']:
                        sent['track'] = 'mic'
                result = combine_transcripts(sys_result, mic_result)
            else:
                result = transcribe_dual_track(mic_path, sys_path, model, device)

    elif len(input_files) == 1:
        # Single file mode
        input_file = input_files[0]
        if not os.path.exists(input_file):
            logger.error(f"Input file not found: {input_file}")
            sys.exit(1)

        logger.info(f"🎤 Transcribing: {input_file}")
        start_run = time.time()

        if args.engine == "mlx":
            result = transcribe_with_mlx(input_file, language=args.language, model=args.mlx_model)
        elif args.engine == "whisperx":
            result = transcribe_with_whisperx(input_file, language=args.language, device=device)
        else:
            # Use FunASR with appropriate language model
            start_load = time.time()
            model = get_funasr_model(device=device, language=args.language)
            logger.info(f"✅ FunASR models loaded in {time.time() - start_load:.2f}s")

            res = model.generate(input=input_file, batch_size_s=300)
            result = res[0] if isinstance(res, list) and len(res) > 0 else {}

        duration = time.time() - start_run
        logger.info(f"✅ Transcription finished in {duration:.2f}s")
    else:
        logger.error(f"Expected 1 or 2 input files, got {len(input_files)}")
        sys.exit(1)

    # 3. Output Handling
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                json.dump(result, f, ensure_ascii=False, indent=2)
            logger.info(f"💾 Result saved to: {args.output}")
        except Exception as e:
            logger.error(f"Failed to write output: {e}")
            sys.exit(1)
    else:
        # If no output file, print JSON to stdout
        print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
