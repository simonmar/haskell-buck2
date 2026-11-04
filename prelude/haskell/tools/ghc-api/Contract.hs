-- | The version of the request, and of what the worker writes back. The
-- rules name it in each request (_WORKER_CONTRACT in compile_per_module.bzl),
-- so that a worker installed for another version of the rules says so rather
-- than misreading the request.
module Contract (contract) where

contract :: String
contract = "3"
