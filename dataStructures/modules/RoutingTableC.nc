#include "../../includes/channels.h"

module RoutingTableC {
    provides interface RoutingTable;
}

implementation {
    Route table[MAX_ROUTING_TABLE_SIZE];
    uint16_t numRoutes = 0;

    //merge the incoming individual Route with the node's RoutingTable.
    command void RoutingTable.mergeRoute(Route route) {
        uint16_t i;
        //checking known routes
        for (i = 0; i < numRoutes; i++) {
            //Look for the corresponding destinations
            if (route.destination == table[i].destination) {
                if (route.cost + 1 < table[i].cost) {
                    // Found a better route
                    break;
                }
                else if (route.nextHop == table[i].nextHop) {
                    // Same destination, same nextHop, but the cost could be different
                    // Assume this information is more up-to-date and replace the old route
                    break;
                }
                else {
                    // Ignore this route
                    return;
                }
            }
        }
        //no matching routes.
        if (i == numRoutes) {
            // Add as a new route
            if (numRoutes < MAX_ROUTING_TABLE_SIZE) {
                numRoutes++;
            }
            else {
                // Not enough space
                return;
            }
        }

        table[i] = route;
        table[i].TTL = MAX_ROUTE_TTL;
        table[i].cost += 1;

        if (table[i].nextHop == 0) {
            // A keyword that indicates this is a route to self
            table[i].cost = 0;
        }
    }

    command void RoutingTable.updateTable(Route* newRoutes, uint16_t numNewRoutes) {
        uint16_t i;

        for (i = 0; i < numNewRoutes; i++) {
            call RoutingTable.mergeRoute(newRoutes[i]);
        }
    }

    command Route* RoutingTable.getTable() {
        return table;
    }

    command uint16_t RoutingTable.lookup(uint16_t destination) {
        // Get the corresponding nextHop for the given destination
        uint16_t i;

        for (i = 0; i < numRoutes; i++) {
            if (destination == table[i].destination && table[i].cost < UNREACHABLE) {
                return table[i].nextHop;
            }
        }

        // Destination is unreachable
        return 0;
    }

    command uint16_t RoutingTable.size() {
        return numRoutes;
    }

    command void RoutingTable.printTable() {
        uint16_t i;
      
        dbg(ROUTING_CHANNEL, "Routing Table[%hhu]:\n", TOS_NODE_ID);
        dbg(ROUTING_CHANNEL, "Dest\tHop\tCount\n");

        for (i = 0; i < numRoutes; i++) {
            dbg(ROUTING_CHANNEL, "%hhu\t\t%hhu\t%hhu\n", table[i].destination, table[i].nextHop, table[i].cost);
        }
    }
}