from TestSim import TestSim

def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("long_line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.TRANSPORT_CHANNEL);

    # Give some time for the nodes to find neighbors and build routing tables
    s.runTime(1000)

    # Designate a node as the server
    s.testServer(1, 100);#mote,port
    #s.runTime(1);
    #s.testServer(1, 200);#mote,port
    s.runTime(60);

    # Designate a node as the client and begin transmission
    #srcMote,srcPort,destMote,destPort,transfer
    #note: client send val 0->transfer to server
    s.testClient(4, 200, 1, 100, 10);
    s.runTime(1);
    #s.testClient(5, 100, 1, 200, 10);
    #s.runTime(1);
    s.runTime(1000);

if __name__ == '__main__':
    main()
