# embed.ph — comptime file inclusion, run right after parsing
import "plang.ph"
import "ast.ph"

def expand_embeds(a: *Arena, m: *Module)
