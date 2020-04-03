/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
#include "includes/CommandMsg.h"
#include "includes/packet.h"

configuration NodeC{
}
implementation {
    components MainC;
    components Node;
    components new AMReceiverC(AM_PACK) as GeneralReceive;

    Node -> MainC.Boot;

    Node.Receive -> GeneralReceive;

    components ActiveMessageC;
    Node.AMControl -> ActiveMessageC;

    components new SimpleSendC(AM_PACK);
    Node.Sender -> SimpleSendC;

    components CommandHandlerC;
    Node.CommandHandler -> CommandHandlerC;

    components new HashmapC(uint16_t, MAX_NEIGHBORS_SIZE) as hmap;
    Node.neighborMap -> hmap;
    components new HashmapC(uint16_t, MAX_NEIGHBORS_SIZE) as aNeighbor;
    Node.activeNeighbors -> aNeighbor;
    
    components new ListC(pack, MAX_CACHE_SIZE) as CacheC;
    Node.Cache -> CacheC;

    components new ListC(pack, MAX_PACKETS_QUEUE_SIZE) as packetsQueueC;
    Node.packetsQueue -> packetsQueueC;

    components RoutingTableC;
    Node.routingTable -> RoutingTableC;

    components new TimerMilliC() as packetsTimerC;
    Node.packetsTimer -> packetsTimerC;

    components new TimerMilliC() as neighborTimerC;
    Node.neighborTimer -> neighborTimerC;

    components new TimerMilliC() as routingTimerC;
    Node.routingTimer -> routingTimerC;

    components RandomC;
    Node.Random -> RandomC;

    components TransportC;
    Node.Transport -> TransportC;
}
