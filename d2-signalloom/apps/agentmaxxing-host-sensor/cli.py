"""
Command-line interface for the AgentMaxxing host sensor artifact hasher.
Outputs structured JSON records matching Signal Loom external-agent wire contracts.
"""

import argparse
import json
import os
import sys

try:
    from .hasher import BoundedArtifactHasher
    from .ratelimit import RateLimiter
except (ImportError, ValueError):
    from hasher import BoundedArtifactHasher
    from ratelimit import RateLimiter


def main() -> int:
    parser = argparse.ArgumentParser(
        description="AgentMaxxing Host Sensor Bounded Hasher CLI",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Subcommand: hash-relative
    hash_parser = subparsers.add_parser(
        "hash-relative",
        help="Hash a file relative to a pinned root directory with TOCTOU checks",
    )
    hash_parser.add_argument(
        "--root-dir", required=True, help="Absolute path to approved root directory"
    )
    hash_parser.add_argument(
        "--relpath", required=True, help="Relative path within the root directory"
    )
    hash_parser.add_argument(
        "--root-id", default="agent-work", help="Approved root ID (e.g. agent-work, agent-output)"
    )
    hash_parser.add_argument(
        "--max-file-size",
        type=int,
        default=16_777_216,
        help="Maximum permissible file size in bytes",
    )
    hash_parser.add_argument(
        "--max-files-per-window",
        type=int,
        default=120,
        help="Max files permitted per 60s window",
    )
    hash_parser.add_argument(
        "--max-bytes-per-window",
        type=int,
        default=67_108_864,
        help="Max bytes permitted per 60s window",
    )

    args = parser.parse_args()

    if args.command == "hash-relative":
        limiter = RateLimiter(
            max_files_per_window=args.max_files_per_window,
            max_bytes_per_window=args.max_bytes_per_window,
            max_file_size_bytes=args.max_file_size,
        )
        hasher = BoundedArtifactHasher(
            rate_limiter=limiter,
            max_file_size_bytes=args.max_file_size,
        )
        result = hasher.hash_relative_path(
            root_dir_path=args.root_dir,
            relpath=args.relpath,
            root_id=args.root_id,
        )
        print(json.dumps(result.to_dict(), indent=2))
        return 0 if result.observation_state == "observed" else 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
