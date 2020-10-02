import random

MOVES = list("neswud")

n = int(input(""))

print("p", end="")
for i in range(n):
    if i % 1000 == 0:
        print("")
    print(random.choice(MOVES), end="")
    
print("p")
