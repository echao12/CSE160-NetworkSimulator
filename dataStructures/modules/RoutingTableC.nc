#include "../../includes/channels.h"

module RoutingTableC {
    provides interface RoutingTable;
}

implementation {
    Route table[MAX_ROUTING_TABLE_SIZE];
    uint16_t numRoutes = 0;

    command void RoutingTable.mergeRoute(Route route) {
        uint16_t i;

        for (i = 0; i < numRoutes; i++) {
            if (route.destination == table[i].destination) {
                if (route.cost + 1 < table[i].cost) {
                    // Found a better route
                    break;
                }
                else if (route.nextHop == table[i].nextHop) {
                    // Same destination, same nextHop, that means the cost to the destination must have changed
                    // In that case, replace the current route with the new one
                    break;
                }
                else {
                    // Ignore this route
                    return;
                }
            }
        }

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
    }

    command void RoutingTable.addNeighbor(uint16_t neighborID) {
        Route newRoute;
        newRoute.destination = neighborID;
        newRoute.nextHop = neighborID;
        newRoute.cost = 0;
        newRoute.TTL = MAX_ROUTE_TTL;
        call RoutingTable.mergeRoute(newRoute);
    }

    command void RoutingTable.updateTable(Route* newRoutes, uint16_t numNewRoutes) {
        uint16_t i;

        for (i = 0; i < numNewRoutes; i++) {
            call RoutingTable.mergeRoute(newRoutes[i]);
        }
    }

    command uint16_t RoutingTable.lookup(uint16_t destination) {
        uint16_t i;

        for (i = 0; i < numRoutes; i++) {
            if (destination == table[i].destination) {
                return table[i].nextHop;
            }
        }

        // No routes
        return MAX_ROUTING_TABLE_SIZE;
    }

    command void RoutingTable.printTable() {
        uint16_t i;
      
        dbg(ROUTING_CHANNEL, "Routing Table:\n");
        dbg(ROUTING_CHANNEL, "Dest\tHop\tCount\n");

        for (i = 0; i < numRoutes; i++) {
            dbg(ROUTING_CHANNEL, "%hhu\t\t%hhu\t%hhu\n", table[i].destination, table[i].nextHop, table[i].cost);
        }
    }
}