# the code behind geo.ph. Note the import: a package's module imports its own
# header in the SAME form whoever uses it imports it.
import <geo/geo.ph>

def geo_area(w: i64, h: i64) -> i64:
    return w * h

def geo_perim(w: i64, h: i64) -> i64:
    return 2 * (w + h)
