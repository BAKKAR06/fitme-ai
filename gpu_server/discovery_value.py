"""Print a value from discovery.json (creating it on first run). Used by the .bat scripts.

    python gpu_server/discovery_value.py key
    python gpu_server/discovery_value.py topic
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tunnel import load_discovery  # noqa: E402

print(load_discovery()[sys.argv[1]])
