//
//  Chest.swift
//  MetalCup
//
//  Created by Kaden Cringle on 1/22/26.
//

class Chest: GameObject {
    
    init() {
        super.init(name: "Chest", meshType: .Chest)
        setScale(0.01)
    }
}
