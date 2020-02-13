from TestSim import TestSim

def main():
    # Initialize simulation
    s = TestSim()
    s.runTime(10)

    # Load the network
    s.loadTopo("linear_loop.topo")
    
    # Add noise
    s.loadNoise("no_noise.txt")
    
    # Turn on the sensors
    s.bootAll()
    
    # Add channels
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.FLOODING_CHANNEL)

    s.runTime(20)

    # Flood the network
    s.flood(1, 2, "Woooosh")
    s.runTime(10)

    s.flood(1, 10, "Woooosh again")
    s.runTime(10)

if __name__ == '__main__':
    main()
