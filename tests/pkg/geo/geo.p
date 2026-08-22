# o código por trás de geo.ph. Note o import: um módulo de pacote importa o
# próprio header pela MESMA forma por que quem o usa o importa.
import <geo/geo.ph>

def geo_area(w: i64, h: i64) -> i64:
    return w * h

def geo_perim(w: i64, h: i64) -> i64:
    return 2 * (w + h)
