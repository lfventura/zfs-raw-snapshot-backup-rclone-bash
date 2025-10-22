#!/bin/bash

# Teste simples para verificar se as mensagens de erro contextuais estão funcionando
# Este script simula diferentes falhas para testar o contexto da trap

# Copiar a função handle_error do script principal
handle_error() {
    local line_number="${1:-UNKNOWN}"
    local exit_status="${2:-UNKNOWN}"
    
    echo "ERROR: Script failed at line $line_number during: ${CURRENT_OPERATION:-"unknown operation"}. EXIT STATUS: $exit_status"
    
    if [ "$exit_status" -ne 0 ]; then
        echo "RECOVERY ACTIONS may be available. Check the script output above."
    fi
}

# Configurar trap
trap 'handle_error ${LINENO} $?' ERR
set -eE

echo "=== TESTING ERROR CONTEXT MESSAGES ==="

echo "Test 1: Simulation of chunk size calculation error"
export CURRENT_OPERATION="calculating chunk size for snapshot pool/dataset@test"
echo "This should fail..." && false

echo "This line should not be reached"