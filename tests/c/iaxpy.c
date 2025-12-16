#define LOOP_CNT 3

extern void eot_sequence();

void _start() {
    int y[LOOP_CNT] = {1, 2, 3};
    int x[LOOP_CNT] = {1, 2, 3};
    int a = 3;

    for (int i = 0; i<LOOP_CNT; i++) {
        y[i] = a*x[i]+y[i];
    }
    eot_sequence();

}