-- | The version of the request that the rules send, and of the files that
-- the worker writes back. Each request names the version that the rules use
-- (_WORKER_CONTRACT in compile_per_module.bzl). A worker or compile tool
-- that was built from another version of the rules then reports the
-- mismatch, rather than misreading the request.
module Contract (contract) where

contract :: String
contract = "2"
