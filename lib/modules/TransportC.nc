#include "../../includes/socket.h"
// Configuration file of Transport
configuration TransportC{
    provides interface Transport;
}

implementation{
    components TransportP;
    Transport = TransportP;
    components new TimerMilliC() as timer;
    components RandomC as Random;

    //Timers
    TransportP.timer0 -> timer;
    TransportP.Random -> Random;
    //Lists
    components new ListC(socket_store_t, 10);
    TransportP.socketList -> ListC;

}