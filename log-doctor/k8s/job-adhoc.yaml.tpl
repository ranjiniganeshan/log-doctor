# One-off Log Doctor run with custom arguments (used by `make dry-run`).
# Not applied by `make deploy`. ${LOG_DOCTOR_ARGS} is a comma-separated list
# of quoted args, e.g.  "--dry-run", "--skip-llm"
apiVersion: batch/v1
kind: Job
metadata:
  generateName: log-doctor-adhoc-
  namespace: log-doctor
  labels:
    app.kubernetes.io/name: log-doctor
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: log-doctor
    spec:
      serviceAccountName: log-doctor
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: log-doctor
          image: ${LOG_DOCTOR_IMAGE}
          args: [${LOG_DOCTOR_ARGS}]
          envFrom:
            - configMapRef:
                name: log-doctor-config
          resources:
            requests: { cpu: 50m, memory: 96Mi }
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
