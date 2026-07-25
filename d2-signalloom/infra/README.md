# Signalloom infrastructure components

`inf-bao` owns the bounded OpenBao/SPIRE slice. `inf-signalloom` owns the
local PostgreSQL, Redis, MinIO, and fake integration proxy slice. Component
roots provide controller/config split and local overlay entry points; workload
manifests are added by their owning implementation cards.
