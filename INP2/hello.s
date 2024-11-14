; Autor reseni: jmeno prijmeni xlogin

; Projekt 2 - INP 2024
; Vigenerova sifra na architekture MIPS64

; DATA SEGMENT
                .data
msg:            .asciiz "jmenoprijmeni"    ; Vstupní zpráva (jméno a příjmení)
key:            .asciiz "pri"            ; Klíč pro šifrování

cipher:         .space  31               ; Výstupní pole pro zašifrovaný text
key_t:          .space  31               ; Místo pro uložení posunů jednotlivých znaků klíče
params_sys5:    .space  8                ; Místo pro adresu řetězce pro výpis

                .text

;                      $t0 ... index pro key a key_t
;                      $t5 ... aktuální znak z key 
;------------------------------------------------------------------------------------------
main:
                xor    $t0, $t0, $t0     ; Index pro klíč (`key`) a posuny (`key_t`)

loop_key:
                lb      $t5, key($t0)     ; Načti aktuální znak klíče do $t5
                beq     $t5, $zero, end_key ; Konec klíče -> jdi na end_key

                addi    $t5, $t5, -96    ; Převod na pořadí (a = 1, b = 2, ...)
                sb      $t5, key_t($t0)  ; Ulož pořadí znaku do key_t
                addi    $t0, $t0, 1      ; Posuň na další znak klíče
                j       loop_key         ; Opakuj pro další znak

end_key:
                xor    $t5, $t5, $t5     ; Reset indexu pro key_t
                xor    $t6, $t6, $t6     ; Reset indexu pro msg


;                       $t7 ... aktuální znak z msg
;                       $t6 ... aktuální index v msg
;                       $t8 ... aktuální znak z key_t
;                       $t5 ... aktální index v key_t
;                       $t3 ... bool hodnota ozačuje zda se má sčítat nebo odčítat (0/1)
;                       $t2 ... pomocný registr s potřebnou konstantou
;                       $t1 ... pomocný registr ukláda zda nerovnost platila/neplatila (1/0)
;                       $t0 ... z minulé smyčky udává délku key (tedy i key_t)
;------------------------------------------------------------------------------------------
loop_msg:
                lb      $t7, msg($t6)        ; Načti znak zprávy do $t7
                beq     $t7, $zero, end_msg  ; Konec zprávy -> jdi na end_msg

                lb      $t8, key_t($t5)      ; Načti posun z key_t
                beq     $t3, $zero, skip_negation ; Pokud $t3 == 0, přeskoč negaci
                sub     $t8, $zero, $t8      ; Negace posunu (pro střídání + a -)
skip_negation:
                add     $t7, $t7, $t8       ; Aplikuj posun na znak zprávy

                ; Zkontroluj, zda je v rozmezí [97, 122] (malá písmena)
                addi    $t2, $zero, 97
                slt     $t1, $t7, $t2       ; $t1 = 1, pokud $t7 < 'a'
                bne     $t1, $zero, below_a ; Pokud menší než 'a', oprav

                addi    $t2, $zero, 122
                slt     $t1, $t2, $t7       ; $t1 = 1, pokud $t7 > 'z'
                bne     $t1, $zero, above_z ; Pokud větší než 'z', oprav
                j       store_result

above_z:
                addi    $t7, $t7, -26       ; Pokud větší než 'z', posuň zpět o 26
                j       store_result
below_a:
                addi    $t7, $t7, 26        ; Pokud menší než 'a', posuň dopředu o 26

store_result:
                sb      $t7, cipher($t6)    ; Ulož upravený znak do cipher
                addi    $t6, $t6, 1         ; Posuň index zprávy a cipher
                addi    $t5, $t5, 1         ; Posuň index pro key_t
                xori    $t3, $t3, 1         ; Přepni mezi kladným a záporným posunem

                slt     $t1, $t5, $t0       ; Otestuj, zda je index pro key_t v rozsahu
                bne     $t1, $zero, loop_msg ; Pokud ano, pokračuj v loop_msg
                xor     $t5, $t5, $t5       ; Reset indexu pro key_t
                j       loop_msg            ; Opakuj pro další znak zprávy

end_msg:
                sb      $zero, cipher($t6)  ; Přidej konec řetězce do cipher

                daddi   r4, r0, cipher      ; Adresa zašifrovaného textu do r4
                jal     print_string        ; Výpis textu

;------------------------------------------------------------------------------------------
; NASLEDUJICI KOD NEMODIFIKUJTE!

                syscall 0                 ; halt

print_string:   ; adresa retezce se ocekava v r4
                sw      r4, params_sys5(r0)
                daddi   r14, r0, params_sys5    ; adr pro syscall 5 musi do r14
                syscall 5   ; systemova procedura - vypis retezce na terminal
                jr      r31 ; return - r31 je urcen na return address
