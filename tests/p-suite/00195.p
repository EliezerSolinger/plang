include <stdio.h>

struct point:
    x: double
    y: double

point_array: point[100]

def main() -> int:
    my_point: int = 10
    point_array[my_point].x = 12.34
    point_array[my_point].y = 56.78
    printf("%f, %f\n", point_array[my_point].x, point_array[my_point].y)
    return 0
