# compile_granularity for a fixture that is tested both ways (see
# BUCK.fixture).
COMPILE_GRANULARITY = select({
    "//compile:make": "target",
    "DEFAULT": "module",
})
