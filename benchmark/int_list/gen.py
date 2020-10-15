import random

N = 10000000 + 500
for i in range(N):
    if (i+1) % 100 == 0:
        sep = '\n'
    else:
        sep = ' '
    print(random.randint(0, 2*N), end=sep)
