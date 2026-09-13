"""
Rate limiting module for host sensor artifact hashing.
Enforces windowed throughput caps and file count limits to prevent denial-of-service
and bounded resource consumption.
"""

import threading
import time
from typing import Dict, List, Optional, Tuple


class RateLimiter:
    """
    Thread-safe windowed rate limiter for artifact hashing.
    Enforces limits on:
      1. Maximum single file size (bytes)
      2. Maximum file count within sliding window
      3. Maximum aggregate byte throughput within sliding window
    """

    def __init__(
        self,
        max_files_per_window: int = 120,
        max_bytes_per_window: int = 67_108_864,  # 64 MiB
        window_seconds: float = 60.0,
        max_file_size_bytes: int = 16_777_216,  # 16 MiB
    ):
        self.max_files_per_window = max_files_per_window
        self.max_bytes_per_window = max_bytes_per_window
        self.window_seconds = window_seconds
        self.max_file_size_bytes = max_file_size_bytes

        self._lock = threading.Lock()
        # History format: list of tuples (timestamp, size_bytes)
        self._history: List[Tuple[float, int]] = []

    def _prune(self, now: float) -> None:
        cutoff = now - self.window_seconds
        self._history = [entry for entry in self._history if entry[0] >= cutoff]

    def check_candidate(
        self, size_bytes: int, now: Optional[float] = None
    ) -> Tuple[bool, Optional[str]]:
        """
        Validates if hashing a candidate file of `size_bytes` is permissible
        under current limits without consuming the budget.

        Returns (allowed: bool, reason_code: Optional[str]).
        """
        if now is None:
            now = time.monotonic()

        if size_bytes > self.max_file_size_bytes:
            return False, "max_file_size_exceeded"

        if size_bytes < 0:
            return False, "invalid_negative_file_size"

        with self._lock:
            self._prune(now)

            current_files = len(self._history)
            current_bytes = sum(entry[1] for entry in self._history)

            if current_files + 1 > self.max_files_per_window:
                return False, "max_files_per_window_exceeded"

            if current_bytes + size_bytes > self.max_bytes_per_window:
                return False, "max_bytes_per_window_exceeded"

            return True, None

    def record_consumption(
        self, size_bytes: int, now: Optional[float] = None
    ) -> Tuple[bool, Optional[str]]:
        """
        Records the actual consumption of `size_bytes` upon successful hashing.
        Returns (allowed: bool, reason_code: Optional[str]).
        """
        if now is None:
            now = time.monotonic()

        with self._lock:
            self._prune(now)

            if size_bytes > self.max_file_size_bytes:
                return False, "max_file_size_exceeded"

            current_files = len(self._history)
            current_bytes = sum(entry[1] for entry in self._history)

            if current_files + 1 > self.max_files_per_window:
                return False, "max_files_per_window_exceeded"

            if current_bytes + size_bytes > self.max_bytes_per_window:
                return False, "max_bytes_per_window_exceeded"

            self._history.append((now, size_bytes))
            return True, None

    def reset(self) -> None:
        """Clears rate limiter history."""
        with self._lock:
            self._history.clear()

    def get_metrics(self, now: Optional[float] = None) -> Dict[str, object]:
        """Returns current utilization metrics."""
        if now is None:
            now = time.monotonic()

        with self._lock:
            self._prune(now)
            current_files = len(self._history)
            current_bytes = sum(entry[1] for entry in self._history)

            return {
                "current_files": current_files,
                "current_bytes": current_bytes,
                "max_files_per_window": self.max_files_per_window,
                "max_bytes_per_window": self.max_bytes_per_window,
                "max_file_size_bytes": self.max_file_size_bytes,
                "window_seconds": self.window_seconds,
                "utilization_files_pct": round(
                    (current_files / self.max_files_per_window) * 100, 2
                )
                if self.max_files_per_window > 0
                else 0.0,
                "utilization_bytes_pct": round(
                    (current_bytes / self.max_bytes_per_window) * 100, 2
                )
                if self.max_bytes_per_window > 0
                else 0.0,
            }
