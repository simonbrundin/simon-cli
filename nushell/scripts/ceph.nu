#!/usr/bin/env nu

# Ceph Status
def "main ceph status" [] {

  kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

}

# Ceph kluster status
def "main ceph cluster" [] {
  kubectl --namespace rook-ceph get cephcluster rook-ceph}

# Ta bort Ceph
def "main ceph delete" [] {
 kubectl --namespace rook-ceph patch cephcluster rook-ceph --type merge -p '{"spec":{"cleanupPolicy":{"confirmation":"yes-really-destroy-data"}}}'
 kubectl delete storageclasses ceph-block ceph-bucket ceph-filesystem
 kubectl --namespace rook-ceph delete cephblockpools ceph-blockpool
 kubectl --namespace rook-ceph delete cephobjectstore ceph-objectstore
 kubectl --namespace rook-ceph delete cephfilesystem ceph-filesystem
}



