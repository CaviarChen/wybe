import random

ops = list("neswud")
print("p")
for i in range(10**7):
    print(random.choice(ops), end="")
    if i+1 % 1000 == 0:
        print()
print("p")
