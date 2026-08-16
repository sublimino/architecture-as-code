# Signal Loom infrastructure components

`inf-bao` owns the OpenBao and SPIRE slice. `inf-signalloom` owns
PostgreSQL, Redis, MinIO, and the fake integration proxy. Each component
root has a controller/config split with local overlay entry points.
