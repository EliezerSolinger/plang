# main.p — entrada do pstudio.
#   pstudio                        -> árvore no diretório atual
#   pstudio <pasta>                -> árvore na pasta
#   pstudio <arq...>               -> abre os arquivos em abas
#   pstudio --shot <img.ppm> ...   -> renderiza 1 frame, grava e sai (headless)
#   pstudio --size 900x600 ...     -> tamanho da janela
include <stdio.h>
include <stdlib.h>
include <string.h>
import "app.ph"
import "psys.ph"

def main(argc: i32, argv: **char) -> i32:
    v: Vfs = vfs_local()
    dir: *char = None
    shot: const *char = None
    win_w: i32 = 1100
    win_h: i32 = 720
    # varredura 1: opções
    i: i32 = 1
    while i < argc:
        if strcmp(argv[i], "--shot") == 0 and i + 1 < argc:
            shot = argv[i + 1]
            i += 2
            continue
        if strcmp(argv[i], "--size") == 0 and i + 1 < argc:
            sep: const *char = strchr(argv[i + 1], 'x')
            if sep != None:
                win_w = atoi(argv[i + 1])
                win_h = atoi(sep + 1)
            i += 2
            continue
        if strncmp(argv[i], "--", 2) == 0:
            fprintf(stderr, "pstudio: opcao desconhecida '%s'\n", argv[i])
            return 2
        i += 1
    # varredura 2: pasta/arquivos
    i = 1
    while i < argc:
        if strcmp(argv[i], "--shot") == 0 or strcmp(argv[i], "--size") == 0:
            i += 2
            continue
        st: PsStat
        if not vfs_stat(in v, argv[i], out st) or not st.exists:
            fprintf(stderr, "pstudio: '%s' nao existe\n", argv[i])
            i += 1
            continue
        if st.is_dir and dir == None:
            dir = ps_path_dirname(ps_path_join(argv[i], "x"))
        elif not st.is_dir and dir == None:
            dir = ps_path_dirname(argv[i])
        i += 1
    if dir == None:
        dir = malloc(2)
        strcpy(dir, ".")

    app: App
    if not app.init(dir, win_w, win_h):
        fprintf(stderr, "pstudio: nao consegui abrir a janela (SDL). Sem DISPLAY?\n")
        free(dir)
        return 1
    free(dir)

    i = 1
    while i < argc:
        if strcmp(argv[i], "--shot") == 0 or strcmp(argv[i], "--size") == 0:
            i += 2
            continue
        st2: PsStat
        if vfs_stat(in v, argv[i], out st2) and st2.exists and not st2.is_dir:
            app.open_file(argv[i])
        i += 1
    app.update_status()

    rc: i32 = 0
    if shot != None:
        rc = 0 if app.screenshot(shot) else 1
    else:
        rc = app.run()
    app.deinit()
    return rc
