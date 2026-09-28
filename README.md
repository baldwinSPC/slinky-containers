# Slinky Containers

> [!NOTE]
> This is baldwinSPC's fork of
> [SlinkyProject/containers](https://github.com/SlinkyProject/containers). It
> adds GPU-capable `slurmd` images, `slurmd_gpu` and `slurmd_gpu_pyxis`, built
> with NVML (linux/amd64 and linux/arm64) and ROCm SMI (linux/amd64), so
> `gres.conf` can use `AutoDetect=nvml` and `AutoDetect=rsmi`. They are
> published to `ghcr.io/baldwinspc/slinky-containers` and are not SchedMD's. See
> [NOTICE-GPU.md](./NOTICE-GPU.md) for their licences and sources.
>
> ```sh
> cd ./schedmd/slurm/
> docker buildx bake --file ./docker-bake.hcl --file ./26.05/rockylinux9/slurm.hcl \
>   --file ./26.05/rockylinux9/gpu.hcl gpu
> ```

[SchedMD] provides the images in the containers repository primarily for use
with [Slinky] - to enable the orchestration of [Slurm] clusters using
[Kubernetes]. These [OCI] container images track [Slurm] releases closely.

## Image Registries

OCI artifacts are pushed to public registries:

- [GitHub][github-registry]

## Build Slurm Images

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./$VERSION/$FLAVOR/slurm.hcl"
docker bake $BAKE_IMPORTS --print
docker bake $BAKE_IMPORTS
```

For example, the following will build Slurm 26.05 on Rocky Linux 9.

```sh
cd ./schedmd/slurm/
export BAKE_IMPORTS="--file ./docker-bake.hcl --file ./26.05/rockylinux9/slurm.hcl"
docker bake $BAKE_IMPORTS --print
docker bake $BAKE_IMPORTS
```

For additional instructions, see the [build guide][build-guide].

## Support and Development

Feature requests, code contributions, and bug reports are welcome!

Github/Gitlab submitted issues and PRs/MRs are handled on a best effort basis.

The SchedMD official issue tracker is at <https://support.schedmd.com/>.

To schedule a demo or simply to reach out, please
[contact SchedMD][contact-schedmd].

## License

Copyright (C) SchedMD LLC.

Licensed under the
[Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0) you
may not use project except in compliance with the license.

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

<!-- Links -->

[build-guide]: ./docs/build.md
[contact-schedmd]: https://www.schedmd.com/slurm-resources/contact-schedmd/
[github-registry]: https://github.com/orgs/SlinkyProject/packages
[kubernetes]: https://kubernetes.io/
[oci]: https://opencontainers.org/
[schedmd]: https://www.schedmd.com/
[slinky]: https://slinky.ai/
[slurm]: https://slurm.schedmd.com/
