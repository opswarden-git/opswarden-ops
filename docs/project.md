 PDF To Markdown Converter

    Debug View
    Result View

Bernstein
BERNSTEIN_

<CONTAINERS SYMPHONY ORCHESTRATION

/>

BERNSTEIN

LeonardBernsteinwasanexceptionalcomposer, pianist, andconductorinhisdays(hismostfamouswork
being the soundtrack of West Side Story ).
Below he's conducting Hector Berlioz's Symphonie fantastique, Op. 14 with the Orchestre National de
France, in 1976.

During this project, you are going to become the Leonard Bernstein of containers!

Orchestration: arrangementofapieceofmusicinpartssothatitcanbeplayedbyanorches-
tra.

— Oxford Advanced Learner’s Dictionary —

The orchestra you are going to conduct is one of the most popular of its kind:Kubernetes.

Kubernetesisanopen-sourceplatformthatallowsyoutomanagecontainerizedapplicationsandservices,
in a scalable and automatic way.

Youwilldeployanapplicationtoamulti-hostclusterusingKubernetes,andyouwilluseTraefikasareverse
proxy and load balancer.

The application you will be working on during this project is a simple web poll application.

There are five elements constituting the application:

3 Poll , a Flask Python web application that gathers votes and push them into a Redis queue ;

3 A Redisqueue , whichholdsthevotessentbythePollapplication, awaitingforthemtobeconsumed
by the Worker ;

3 The Worker , aJavaapplicationwhichconsumesthevotesbeingintheRedisqueue, andstoresthem
into a PostgreSQL database ;

3 A PostgreSQL database , which (persistently) stores the votes stored by the Worker ;

3 Result , a Node.js web application that fetches the votes from the database and displays the... well,
result. ;)

This looks familiar does not it?

Specifications

You have to define:

3 1 load balancer ;
3 2 databases ;
3 3 services (two of which will be routed using Traefik ).

You will also have to define a monitoring tool to get information on your containers.

Databases

3 redis:

- Based onredis:5.0.
- Namespace:default.
- Not replicated.
- Always restarts.
- Exposes port 6379.
- Is not enabled in Traefik.

3 postgres:

- Based onpostgres:xx.
- Namespace:default.
- Not replicated.
- Always restarts.
- Exposes port 5432.
- Is not enabled in Traefik.
- Has a persistent volume:/var/lib/postgresql/data.
- Environment variables:POSTGRES_HOST,POSTGRES_PORT,POSTGRES_DB,POSTGRES_USER,POSTGRES_PASSWORD

Services

3 poll:

- Based onepitechcontent/t-dop-600-poll:k 8 s.
- Namespace:default.
- Replicated: once (== 2 instances).
- Always restarts.
- Memory limit of 128M.
- Exposes port 80.
- Has a Traefik rule matchingpoll.dop.iohost and proxying topollservice.
- Environment variables:REDIS_HOST

3 worker:

- Based onepitechcontent/t-dop-600-worker:k 8 s.
- Namespace:default.
- Not replicated.
- Memory limit of 256M.
- Always restarts.
- Is not enabled in Traefik.
- Environmentvariables:REDIS_HOST,POSTGRES_HOST,POSTGRES_PORT,POSTGRES_DB,POSTGRES_USER,POSTGRES
_PASSWORD

3 result:

- Based onepitechcontent/t-dop-600-result:k 8 s.
- Namespace:default.
- Replicated: once (== 2 instances).
- Memory limit of 128M.
- Always restarts.
- Exposes port 80.
- Has a Traefik rule matchingresult.dop.iohost and proxying toresultservice.
- Environment variables:POSTGRES_HOST,POSTGRES_PORT,POSTGRES_DB,POSTGRES_USER,POSTGRES_PASSWORD

Load balancer

3 traefik:

- Based ontraefik:2.7.
- Namespace:kube-public.
- Replicated: once (== 2 instances).
- Always restarts.
- Needs authorization to access Kubernetes internal API.
- Exposes port 80 (HTTP proxy) and 8080 (admin dashboard) into Kubernetes cluster.
- Exposes port 30021 (HTTP proxy) and 30042 (admin dashboard) on host.

Monitoring tool

3 cadvisor:

- Based ongcr.io/cadvisor/cadvisor:latest.
- Namespace:kube-system.
- Scheduled on all nodes.
- Always restarts.
- Exposes port 8080.

In order to improve high availability, replicated services must run on different nodes.

Common environment variables must be stored in Kubernetes' ConfigMap.

POSTGRES_USERandPOSTGRES_PASSWORDmust be stored in Kubernetes' Secrets.

At the end of the project, you should be able to open thepollapplication into your browser:

3 Result ->result.dop.io:30021;
3 Poll ->poll.dop.io:30021;
3 Traefik dashboard ->localhost:30042.

The expected deployment process is the following:

∇ Terminal - + x
$> kubectl apply -f cadvisor.daemonset.yaml

∇ Terminal - + x
$> kubectl apply -f postgres.secret.yaml -f postgres.configmap.yaml -f
postgres.volume.yaml -f postgres.deployment.yaml -f postgres.service.yaml

∇ Terminal - + x
$> kubectl apply -f redis.configmap.yaml -f redis.deployment.yaml -f redis.service.yaml

∇ Terminal - + x
$> kubectl apply -f poll.deployment.yaml -f worker.deployment.yaml -f
result.deployment.yaml -f poll.service.yaml -f result.service.yaml -f poll.ingress.yaml
-f result.ingress.yaml

∇ Terminal - + x
$> kubectl apply -f traefik.rbac.yaml -f traefik.deployment.yaml -f traefik.service.yaml

∇ Terminal - + x
$> echo "CREATE TABLE votes (id text PRIMARY KEY, vote text NOT NULL);" | kubectl exec -i
-c -- psql -U

∇ Terminal - + x
$> echo "$(kubectl get nodes -o jsonpath='{ $.items[*].status.addresses[?(@.type ==
"ExternalIP")].address }') poll.dop.io result.dop.io" | sudo tee -a /etc/hosts

Environment

You will need at least 1 Kubernetes master and 2 nodes (workers).
You can run it locally, but it is highly recommended to use a ”Kubernetes as a Service” platform.
Examples of such platforms include (but are not limited to) Amazon Elastic Kubernetes Service , Google
Kubernetes Engine , and Digital Ocean.

See also the cloud platforms there:https://education.github.com/pack.

Installing a full Kubernetes cluster locally is complex. Minikube is also not built for multi-node clusters
( which you need for your project ). Take a look atK3s.

Technical formalities

Your project will be entirely evaluated with Automated Tests, by analyzing your configuration files.

In order to be correctly evaluated, your repository should at least contain the following files:

∇ Terminal - + x
$> find ./cadvisor.daemonset.yaml ./poll.deployment.yaml ./poll.ingress.yaml
./poll.service.yaml ./postgres.configmap.yaml ./postgres.deployment.yaml
./postgres.secret.yaml ./postgres.service.yaml ./postgres.volume.yaml
./redis.configmap.yaml ./redis.deployment.yaml ./redis.service.yaml
./result.deployment.yaml ./result.ingress.yaml ./result.service.yaml
./traefik.deployment.yaml ./traefik.rbac.yaml ./traefik.service.yaml
./worker.deployment.yaml

Read this list carefully and ask yourselves what need to be in each file.

    v 1.

This is a offline tool, your data stays locally and is not send to any server!

Feedback & Bug Reports
