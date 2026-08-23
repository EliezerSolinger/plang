# um membro que o módulo `os` não declara. (Já foi `os.spawn`, até ao dia em que
# o laço de desenvolvimento precisou dele — o que é o melhor motivo possível
# para um teste destes mudar de nome.)
import os
os.reboot("agora")
