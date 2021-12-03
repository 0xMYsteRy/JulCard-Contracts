# JulCard contracts
compile 

    npx hardhat compile
    
deployment 

    npx hardhat deploy --network fantom

old deploy commads    

    npx hardhat run scripts/deploy.js --network maticmainnet

verify contract

    npx hardhat verify --network fantom 0xAD4BFe9fee174c3E6B4EF94BCf8e2D5E71615A2f "" ""
    npx hardhat verify --network fantom 0x427a3415489Ed14eAB0452CA887636C607ab3e52 "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83" "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75" "0x5Cc61A78F164885776AA610fb0FE1257df78E59B"


