int main(void) { int a[2]; void *p = a; void *q = a + 1; int *ip = a; return p < ip; }
