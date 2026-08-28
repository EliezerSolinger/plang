/* carga.c — um gerador de carga HTTP, e o MESMO para todos os servidores.
 *
 * Existe porque nesta máquina não há `wrk` nem `oha` nem `ab`, e porque um
 * gerador escrito na linguagem que está a ser medida seria a pior escolha
 * possível: se ele fosse o gargalo, os três servidores dariam o mesmo número e o
 * banco de ensaio não diria nada.
 *
 * O que ele faz e nada mais: N threads, cada uma com C conexões keep-alive, a
 * mandar o mesmo pedido em pipeline de profundidade 1 durante T segundos. Conta
 * as respostas completas (pela contagem de `\r\n\r\n` mais o corpo) e reporta
 * pedidos por segundo e a latência média.
 *
 * O que ele NÃO faz, dito: não mede percentis (precisaria de guardar cada
 * amostra), não faz pipelining profundo, e não distingue um 500 de um 200 — o
 * portão do servidor é que garante que as respostas estão certas, e aqui o que se
 * mede é quantas cabem num segundo.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <time.h>
#include <errno.h>

static int      g_port, g_conns, g_secs;
static char     g_req[1024];
static size_t   g_reqlen;
static volatile int g_stop = 0;

static double agora(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

typedef struct { long feitos; long erros; double soma_lat; long e_liga; long e_escreve; long e_le; } Res;

static int liga(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int um = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &um, sizeof um);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(g_port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    return fd;
}

/* Uma resposta inteira: os cabeçalhos até `\r\n\r\n`, e depois o corpo pelo
 * `content-length`. Sem isto o contador contaria pacotes e não respostas. */
static int le_resposta(int fd, char *buf, size_t cap) {
    size_t n = 0;
    char *fim = NULL;
    while (!fim) {
        ssize_t k = read(fd, buf + n, cap - n - 1);
        if (k <= 0) {
            if (getenv("CARGA_DUMP")) {
                buf[n] = 0;
                fprintf(stderr, "[cabecalhos: read=%zd errno=%d apos %zu bytes] %.200s\n",
                        k, errno, n, n ? buf : "(nada)");
            }
            return -1;
        }
        n += (size_t)k;
        buf[n] = 0;
        fim = strstr(buf, "\r\n\r\n");
        if (n >= cap - 1) return -1;
    }
    long clen = 0;
    char *cl = strcasestr(buf, "content-length:");
    if (cl) clen = strtol(cl + 15, NULL, 10);
    size_t precisa = (size_t)(fim - buf) + 4 + (size_t)clen;
    while (n < precisa) {
        ssize_t k = read(fd, buf + n, cap - n - 1);
        if (k <= 0) {
            if (getenv("CARGA_DUMP"))
                fprintf(stderr, "[corpo: read=%zd errno=%d tinha %zu de %zu]\n", k, errno, n, precisa);
            return -1;
        }
        n += (size_t)k;
    }
    if (getenv("CARGA_DUMP") && n > precisa)
        fprintf(stderr, "[LEU A MAIS: %zu de %zu esperados]\n", n, precisa);
    return 0;
}

static void *thread_main(void *arg) {
    Res *r = (Res *)arg;
    int *fds = calloc((size_t)g_conns, sizeof(int));
    char *buf = malloc(1 << 16);
    for (int i = 0; i < g_conns; i++) fds[i] = liga();
    while (!g_stop) {
        for (int i = 0; i < g_conns && !g_stop; i++) {
            if (fds[i] < 0) { fds[i] = liga(); if (fds[i] < 0) { r->erros++; r->e_liga++; continue; } }
            double t0 = agora();
            if (write(fds[i], g_req, g_reqlen) != (ssize_t)g_reqlen) {
                close(fds[i]); fds[i] = -1; r->erros++; r->e_escreve++; continue;
            }
            if (le_resposta(fds[i], buf, 1 << 16) != 0) {
                close(fds[i]); fds[i] = -1; r->erros++; r->e_le++; continue;
            }
            r->soma_lat += agora() - t0;
            r->feitos++;
        }
    }
    for (int i = 0; i < g_conns; i++) if (fds[i] >= 0) close(fds[i]);
    free(fds); free(buf);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "uso: carga <porto> <threads> <conns-por-thread> <segundos> [caminho]\n");
        return 2;
    }
    g_port  = atoi(argv[1]);
    int nth = atoi(argv[2]);
    g_conns = atoi(argv[3]);
    g_secs  = atoi(argv[4]);
    const char *caminho = argc > 5 ? argv[5] : "/";
    g_reqlen = (size_t)snprintf(g_req, sizeof g_req,
        "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n", caminho);

    pthread_t *ts = calloc((size_t)nth, sizeof(pthread_t));
    Res *rs = calloc((size_t)nth, sizeof(Res));
    double t0 = agora();
    for (int i = 0; i < nth; i++) pthread_create(&ts[i], NULL, thread_main, &rs[i]);
    sleep((unsigned)g_secs);
    g_stop = 1;
    for (int i = 0; i < nth; i++) pthread_join(ts[i], NULL);
    double dt = agora() - t0;

    long feitos = 0, erros = 0, el = 0, ee = 0, er = 0; double lat = 0;
    for (int i = 0; i < nth; i++) {
        feitos += rs[i].feitos; erros += rs[i].erros; lat += rs[i].soma_lat;
        el += rs[i].e_liga; ee += rs[i].e_escreve; er += rs[i].e_le;
    }
    printf("%.0f %ld %.3f", feitos / dt, erros, feitos ? lat * 1000.0 / feitos : 0.0);
    if (getenv("CARGA_DETALHE")) printf(" (liga=%ld escreve=%ld le=%ld)", el, ee, er);
    printf("\n");
    return 0;
}
