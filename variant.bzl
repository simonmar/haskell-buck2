# A target as another configuration builds it: `actual`, through the
# incoming transition of the variant (a build of the RTS for another of its
# ways, say).

def _variant_impl(ctx: AnalysisContext) -> list[Provider]:
    return ctx.attrs.actual.providers

_variant = rule(
    impl = _variant_impl,
    attrs = {"actual": attrs.dep()},
    supports_incoming_transition = True,
)

def variant(name, actual, transition, **kwargs):
    """`actual`, configured by `transition` (a transition target)."""
    _variant(name = name, actual = actual, incoming_transition = transition, **kwargs)
