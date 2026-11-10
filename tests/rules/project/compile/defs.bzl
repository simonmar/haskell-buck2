# per_module for a fixture that is tested both ways (see BUCK.fixture).
PER_MODULE = select({
    "//compile:make": False,
    "DEFAULT": True,
})
