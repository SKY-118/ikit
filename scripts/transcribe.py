#!/usr/bin/env python3
import os
import sys
import json
import argparse
import time
import logging

# Configure Logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def check_environment():
    try:
        import torch
        import funasr
        import modelscope
    except ImportError as e:
        logger.error(f"Missing dependency: {e}")
        logger.error("Please install dependencies: pip install torch torchaudio funasr modelscope")
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="iKit FunASR Transcriber (Paraformer + Cam++)")
    parser.add_argument("input_file", help="Path to the input audio file")
    parser.add_argument("--output", "-o", help="Path to save the output JSON", default=None)
    parser.add_argument("--device", "-d", help="Device to use (mps, cpu, cuda)", default=None)
    args = parser.parse_args()

    check_environment()
    from funasr import AutoModel
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

    # 2. Model Initialization
    # We use the standard Paraformer-zh + Cam++ pipeline for best diarization
    try:
        start_load = time.time()
        model = AutoModel(
            model="paraformer-zh",
            vad_model="fsmn-vad",
            punc_model="ct-punc",
            spk_model="cam++",
            device=device,
            disable_update=True,
            log_level="ERROR" 
        )
        logger.info(f"✅ Models loaded in {time.time() - start_load:.2f}s")
    except Exception as e:
        logger.error(f"Failed to load models: {e}")
        sys.exit(1)

    # 3. Inference
    if not os.path.exists(args.input_file):
        logger.error(f"Input file not found: {args.input_file}")
        sys.exit(1)

    try:
        logger.info(f"🎤 Transcribing: {args.input_file}")
        start_run = time.time()
        
        res = model.generate(
            input=args.input_file,
            batch_size_s=300,
            # hotword='iKit', # Future: Make this configurable
        )
        
        duration = time.time() - start_run
        logger.info(f"✅ Transcription finished in {duration:.2f}s")
    except Exception as e:
        logger.error(f"Inference failed: {e}")
        sys.exit(1)

    # 4. Output Handling
    output_data = res[0] if isinstance(res, list) and len(res) > 0 else {}
    
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                json.dump(output_data, f, ensure_ascii=False, indent=2)
            logger.info(f"💾 Result saved to: {args.output}")
        except Exception as e:
            logger.error(f"Failed to write output: {e}")
            sys.exit(1)
    else:
        # If no output file, print JSON to stdout
        print(json.dumps(output_data, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
