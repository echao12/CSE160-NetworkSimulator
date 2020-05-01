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
    s.addChannel(s.APPLICATION_CHANNEL);

    # Give some time for the nodes to find neighbors and build routing tables
    s.runTime(1000)

    # Designate a node as the server
    s.testServer(1, 41);#mote,port
    #s.runTime(1);
    #s.testServer(1, 200);#mote,port
    s.runTime(60);
    s.hello(3, "Eric", 10);
    s.runTime(60);
    s.message(3, "PENTAKILL");
    s.runTime(60);
    s.whisper(3, "Michael", "MID MIA");
    s.runTime(60);
    s.listusr(3);

    s.runTime(500);

if __name__ == '__main__':
    main()