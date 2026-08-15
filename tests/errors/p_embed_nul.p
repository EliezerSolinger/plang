# embed() yields a C string; a nul byte inside would silently truncate it
X: const *char = embed("p_embed_nul.bin")
