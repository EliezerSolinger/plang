# um `bytes` é imutável por contrato: um par que escreve não se faz sobre ele
import "../run/pmod_blob.ph"


blob_dobra(b"\x01\x02")
