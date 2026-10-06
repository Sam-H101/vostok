// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef VOSTOK_RENDER_ENGINE_CLOUD_PARAMETERS_H_INCLUDED
#define VOSTOK_RENDER_ENGINE_CLOUD_PARAMETERS_H_INCLUDED
namespace vostok {

namespace configs {

class binary_config_value;

} // namespace configs

namespace render {

struct cloud_parameters {
	typedef configs::binary_config_value ConfigType;

	cloud_parameters( ) { }

	// declared only: retail never defines or calls it
	void load(
		configs::binary_config_value const&
	);


	u32		grid_width;
	u32		grid_height;
	float	volume_width;
	u32		noise_resulution;
	float	noise_period;
};

STATIC_SIZE_ASSERT( cloud_parameters, 0x14 );

} // namespace render
} // namespace vostok

#endif // #ifndef VOSTOK_RENDER_ENGINE_CLOUD_PARAMETERS_H_INCLUDED
