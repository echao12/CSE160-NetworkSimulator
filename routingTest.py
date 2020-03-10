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
    s.addChannel(s.GENERAL_CHANNEL)
    s.addChannel(s.ROUTING_CHANNEL)

    # Give some time for the nodes to find neighbors and build routing tables
    s.runTime(1000)

    # Print neighbors
    # for nodeID in range(1, s.numMote+1):
    #     s.neighborDMP(nodeID)
    #     s.runTime(10)

    # Print routing tables
    for nodeID in range(1, s.numMote+1):
        s.routeDMP(nodeID)
        s.runTime(10)

    # Test by pinging a node
    s.ping(1, 10, "This is a test")
    s.runTime(1000)

    # Test by pinging a node that is out of range
    s.ping(1, 19, "This is also a test")
    s.runTime(1000)

if __name__ == '__main__':
    main()
