# importing a module does NOT make its names visible bare (41.3): `ORIGIN` has
# to be qualified or brought over with `from`
import lib_geom

print(f"{ORIGIN.x}")
