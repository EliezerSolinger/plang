# core.ph — edição de texto do pstudio (HEADLESS: testável sem janela).
#
# Buffer = array de linhas (bytes UTF-8, cursor/seleção por CODEPOINT).
# Multi-caret real (ctrl+d) desde o v0.1. Undo coalescido: digitação contínua
# agrupa; quebra em espaço/enter/pausa (~700ms)/movimento. Highlight: relexa o
# ARQUIVO INTEIRO com o lexer REAL do compilador em modo tolerante (lex_ex).
#
# Os containers são a STL do projeto (Vec<T>) — mesma dieta do compilador.
include <stddef.h>
import "../stl/vec.ph"

struct BufLine:
    text: *char       # bytes UTF-8, SEM \n, NUL-terminado (malloc)
    ncp: i32          # codepoints (cache p/ movimento e layout)

struct Caret:
    line: i32         # 0-based
    col: i32          # índice de CODEPOINT na linha
    aline: i32        # âncora da seleção (== line/col quando não há seleção)
    acol: i32
    goal: i32         # coluna alvo p/ movimento vertical (-1 = usa col)

enum EditOpKind:
    OP_INSERT
    OP_DELETE

struct EditOp:
    kind: EditOpKind
    line: i32         # início da edição (codepoints)
    col: i32
    text: *char       # o texto inserido/apagado (pode conter \n; malloc)

declare Vec<BufLine>
declare Vec<Caret>
declare Vec<EditOp>

struct UndoGroup:
    ops: Vec<EditOp>
    before: Vec<Caret>   # snapshot dos carets antes do grupo
    after: Vec<Caret>    # e depois (p/ redo)

declare Vec<UndoGroup>

struct Buffer:
    lines: Vec<BufLine>
    carets: Vec<Caret>   # SEMPRE >= 1, ordenados por posição
    undo: Vec<UndoGroup>
    redo: Vec<UndoGroup>
    group_open: bool     # coalescência de digitação
    last_ms: i64
    crlf: bool           # EOL detectado na carga (preservado no save)
    dirty: bool
    version: u64         # incrementa a cada edição (o highlight/draw observa)

    # ---- ciclo de vida ----
    def init(out self: Buffer)                    # 1 linha vazia, 1 caret
    def deinit(ref self: Buffer)
    def load(ref self: Buffer, data: const *char, len: usize)   # detecta CRLF
    def save_text(ref self: Buffer, out len: usize) -> *char     # EOL preservado

    # ---- consulta ----
    def nlines(in self: Buffer) -> i32
    def ncarets(in self: Buffer) -> i32
    def line_text(in self: Buffer, line: i32) -> const *char
    def line_cp(in self: Buffer, line: i32) -> i32       # codepoints da linha
    # byte offset do codepoint `col` dentro da linha (p/ desenhar/recortar)
    def col_byte(in self: Buffer, line: i32, col: i32) -> i32
    def has_sel(in self: Buffer) -> bool                 # algum caret com seleção?
    def sel_text(ref self: Buffer, k: i32) -> *char      # malloc; None sem seleção
    def caret(ref self: Buffer, k: i32) -> *Caret
    # limites ordenados da seleção do caret k (iguais quando não há seleção)
    def sel_range(in self: Buffer, k: i32, out l0: i32, out c0: i32, out l1: i32, out c1: i32)
    def range_text(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32) -> *char

    # ---- edição (aplica em TODOS os carets; now_ms coalesce o undo) ----
    def insert(ref self: Buffer, text: const *char, now_ms: i64)
    # um texto POR CARET (colar multi-caret estilo Sublime); n deve ser ncarets
    def insert_each(ref self: Buffer, texts: **char, n: i32, now_ms: i64)
    def backspace(ref self: Buffer, now_ms: i64)
    def delete_fwd(ref self: Buffer, now_ms: i64)
    def delete_sel(ref self: Buffer, now_ms: i64)        # só as seleções
    # substitui o trecho por texto (usado pela indentação/busca); 1 caret no fim
    def replace_range(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32, text: const *char, now_ms: i64)

    # ---- movimento (sel=True estende a seleção; quebra o grupo de undo) ----
    def move_h(ref self: Buffer, delta: i32, sel: bool)
    def move_v(ref self: Buffer, delta: i32, sel: bool)
    def move_word(ref self: Buffer, dir: i32, sel: bool)  # ctrl+setas
    def home(ref self: Buffer, sel: bool)                 # smart: indent <-> col 0
    def end(ref self: Buffer, sel: bool)
    def move_to(ref self: Buffer, line: i32, col: i32)     # 1 caret na posição
    def select_range(ref self: Buffer, l0: i32, c0: i32, l1: i32, c1: i32)
    def select_all(ref self: Buffer)
    def collapse(ref self: Buffer)                         # 1 caret, sem seleção
    def add_caret(ref self: Buffer, line: i32, col: i32)   # alt+click
    def select_word_at(ref self: Buffer, k: i32) -> bool   # duplo clique

    # ---- multi-caret (ctrl+d, modelo Sublime) ----
    # sem seleção: seleciona a palavra sob cada caret; com seleção: adiciona um
    # caret na PRÓXIMA ocorrência do texto do último caret (com wrap)
    def ctrl_d(ref self: Buffer)

    # ---- busca ----
    # substring simples; wrap circular. False se não achou.
    def find(in self: Buffer, needle: const *char, from_line: i32, from_col: i32,
             forward: bool, out l: i32, out c: i32) -> bool
    # POSIX regex (libc): a busca em modo regex do editor. Só dentro de 1 linha.
    def find_re(in self: Buffer, pattern: const *char, from_line: i32, from_col: i32,
                forward: bool, out l: i32, out c0: i32, out c1: i32) -> bool

    # ---- undo ----
    def undo_step(ref self: Buffer) -> bool
    def redo_step(ref self: Buffer) -> bool
    def break_group(ref self: Buffer)             # movimento/clique quebram
    def mark_saved(ref self: Buffer)              # após salvar: limpa dirty

# ---- highlight (relex total com o lexer do compilador, tolerante) ----
HL_TEXT: const u8 = 0
HL_KW: const u8 = 1
HL_STR: const u8 = 2
HL_NUM: const u8 = 3
HL_COMMENT: const u8 = 4
HL_PUNCT: const u8 = 5

struct HlSpan:
    col: i32          # codepoint inicial
    len: i32          # em codepoints
    cls: u8

declare Vec<HlSpan>

struct HlLine:
    spans: Vec<HlSpan>

declare Vec<HlLine>

struct Highlight:
    lines: Vec<HlLine>   # 1 por linha do buffer
    version: u64         # versão do buffer a que corresponde
    enabled: bool        # False = arquivo não-P (nenhum span)

    def init(out self: Highlight, enabled: bool)
    def deinit(ref self: Highlight)
    # recomputa se version != b.version (arquivo inteiro; barato o suficiente)
    def update(ref self: Highlight, ref b: Buffer)
    # classe do codepoint `col` da linha (HL_TEXT quando fora de qualquer span)
    def class_at(in self: Highlight, line: i32, col: i32) -> u8
