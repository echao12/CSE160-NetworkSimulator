from TestSim import TestSim

def main():
    # Initialize simulation
    s = TestSim()
    s.runTime(10)

    # Load the network
    s.loadTopo("long_line.topo")
    
    # Add noise
    s.loadNoise("no_noise.txt")
    
    # Turn on the sensors
    s.bootAll()
    
    # Add channels
#    s.addChannel(s.COMMAND_CHANNEL)
#    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)

    s.runTime(20)

    # Ping to start neighbor discovery
    s.ping(1, 2, "Hello there")
    s.runTime(100)
    
    # Print neighbors
    for nodeID in range(1, s.numMote+1):
        s.neighborDMP(nodeID)
        s.runTime(10)

    # Print routing tables
    for nodeID in range(1, s.numMote+1):
        s.routeDMP(nodeID)
        s.runTime(10)

if __name__ == '__main__':
    main()
