import Config

# Ash 3.33 asks every app to state this explicitly rather than inherit a
# default that may change. :mixed preserves the historical behaviour.
config :ash, default_string_length_count: :mixed

# The test graph is in-memory: no path, so nothing touches disk and each run
# starts clean.
config :ash_glider, AshGlider.Test.Graph, []
