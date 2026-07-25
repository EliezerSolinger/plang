# font_atlas.ph — GERADO por pstudio/tools/mkatlas.c (ver font_atlas.p).
# Atlas mono 16px: celula 8x16, baseline 12, glifos ASCII 32..126,
# Latin-1 160..255 (acentos), pontuacao tipografica e U+25A1 no fim.
# fa_pixels() e um grid de alpha 8-bit: o glifo i ocupa os bytes
# [i*cw*ch, (i+1)*cw*ch); use fa_index(cp) para achar o i.

def fa_cell_w() -> i32
def fa_cell_h() -> i32
def fa_baseline() -> i32
def fa_count() -> i32
def fa_index(cp: u32) -> i32
def fa_pixels() -> const *u8
