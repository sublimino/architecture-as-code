import os
import sys
from pathlib import Path

# The committed contracts are the fixtures. In the image build CONTRACTS_DIR
# is set (/contracts); running from the repo, fall back to the checkout.
if not os.environ.get("CONTRACTS_DIR"):
    repo_root = Path(__file__).resolve().parents[3]
    os.environ["CONTRACTS_DIR"] = str(repo_root / "contracts")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
